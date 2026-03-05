#!/usr/bin/env python3
"""
Keycloak Setup — Automated Realm, Client, and Group Configuration.

Called by post-enable.sh after Keycloak is healthy.
Configures the 'ancroo' realm with groups, roles, and OAuth2 clients
for Open WebUI, BookStack, and oauth2-proxy.

Usage:
    python3 keycloak-setup.py \
        --admin-user admin \
        --admin-password <password> \
        --base-domain example.com \
        --keycloak-url http://<keycloak-container-ip>:8080

Note: Keycloak has no host port mapping. The URL must point to
the container IP (resolved by post-enable.sh via docker inspect).
"""
import argparse
import json
import sys
import urllib.request
import urllib.error
import urllib.parse
import secrets
import string


def api_request(url, method="GET", data=None, token=None):
    """Make an HTTP request to the Keycloak Admin REST API."""
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    body = json.dumps(data).encode("utf-8") if data else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            if resp.status == 204:
                return None
            content = resp.read().decode("utf-8")
            return json.loads(content) if content else None
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8", errors="replace")
        # 409 Conflict = already exists, which is fine for idempotency
        if e.code == 409:
            return None
        raise RuntimeError(f"HTTP {e.code} {e.reason}: {error_body}") from e


def get_admin_token(base_url, username, password):
    """Obtain an admin access token from the master realm."""
    url = f"{base_url}/realms/master/protocol/openid-connect/token"
    data = urllib.parse.urlencode({
        "grant_type": "password",
        "client_id": "admin-cli",
        "username": username,
        "password": password,
    }).encode("utf-8")

    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")

    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))["access_token"]


def generate_secret(length=48):
    """Generate a cryptographically secure random string."""
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def get_or_create_realm(base_url, token, realm_name):
    """Create realm if it doesn't exist."""
    url = f"{base_url}/admin/realms"
    try:
        api_request(f"{url}/{realm_name}", token=token)
        print(f"  Realm '{realm_name}' existiert bereits")
        return
    except (RuntimeError, urllib.error.HTTPError):
        pass

    api_request(url, method="POST", token=token, data={
        "realm": realm_name,
        "enabled": True,
        "registrationAllowed": False,
        "resetPasswordAllowed": True,
        "loginWithEmailAllowed": True,
        "duplicateEmailsAllowed": False,
        "sslRequired": "none",  # TLS handled by Traefik
    })
    print(f"  Realm '{realm_name}' erstellt")


def get_or_create_group(base_url, token, realm, group_name):
    """Create a group if it doesn't exist. Returns the group ID."""
    url = f"{base_url}/admin/realms/{realm}/groups"
    groups = api_request(f"{url}?search={group_name}", token=token) or []

    for g in groups:
        if g["name"] == group_name:
            return g["id"]

    api_request(url, method="POST", token=token, data={"name": group_name})

    # Fetch again to get the ID
    groups = api_request(f"{url}?search={group_name}", token=token) or []
    for g in groups:
        if g["name"] == group_name:
            print(f"  Gruppe '{group_name}' erstellt")
            return g["id"]

    raise RuntimeError(f"Gruppe '{group_name}' konnte nicht erstellt werden")


def set_default_group(base_url, token, realm, group_id):
    """Set a group as default for new users."""
    url = f"{base_url}/admin/realms/{realm}/default-groups/{group_id}"
    api_request(url, method="PUT", token=token)


def get_or_create_client(base_url, token, realm, client_data):
    """Create an OIDC client if it doesn't exist. Returns client UUID and secret."""
    client_id = client_data["clientId"]
    url = f"{base_url}/admin/realms/{realm}/clients"

    # Check if client exists
    existing = api_request(f"{url}?clientId={client_id}", token=token) or []
    if existing:
        client_uuid = existing[0]["id"]
        print(f"  Client '{client_id}' existiert bereits")
    else:
        api_request(url, method="POST", token=token, data=client_data)
        existing = api_request(f"{url}?clientId={client_id}", token=token) or []
        if not existing:
            raise RuntimeError(f"Client '{client_id}' konnte nicht erstellt werden")
        client_uuid = existing[0]["id"]
        print(f"  Client '{client_id}' erstellt")

    # Get client secret (only for confidential clients)
    client_secret = None
    if not client_data.get("publicClient", False):
        secret_data = api_request(
            f"{url}/{client_uuid}/client-secret", token=token
        )
        if secret_data and secret_data.get("value"):
            client_secret = secret_data["value"]
        else:
            # Generate new secret
            secret_data = api_request(
                f"{url}/{client_uuid}/client-secret",
                method="POST", token=token,
            )
            client_secret = secret_data["value"] if secret_data else None

    # Add group membership mapper
    add_group_mapper(base_url, token, realm, client_uuid, client_id)

    return client_uuid, client_secret


def add_group_mapper(base_url, token, realm, client_uuid, client_id):
    """Add a group membership protocol mapper to a client."""
    url = f"{base_url}/admin/realms/{realm}/clients/{client_uuid}/protocol-mappers/models"

    # Check if mapper already exists
    mappers = api_request(
        f"{base_url}/admin/realms/{realm}/clients/{client_uuid}/protocol-mappers/models",
        token=token,
    ) or []

    for m in mappers:
        if m.get("name") == "groups":
            return  # Already exists

    api_request(url, method="POST", token=token, data={
        "name": "groups",
        "protocol": "openid-connect",
        "protocolMapper": "oidc-group-membership-mapper",
        "consentRequired": False,
        "config": {
            "full.path": "false",
            "id.token.claim": "true",
            "access.token.claim": "true",
            "claim.name": "groups",
            "userinfo.token.claim": "true",
        },
    })


def main():
    parser = argparse.ArgumentParser(description="Keycloak Setup for Ancroo")
    parser.add_argument("--admin-user", required=True)
    parser.add_argument("--admin-password", required=True)
    parser.add_argument("--base-domain", required=True)
    parser.add_argument("--keycloak-url", default="http://localhost:8080")
    args = parser.parse_args()

    base_url = args.keycloak_url.rstrip("/")
    realm = "ancroo"
    auth_domain = f"auth.{args.base_domain}"

    print("Keycloak Setup starten...")
    print()

    # 1. Get admin token
    print("[1/6] Admin Token holen...")
    token = get_admin_token(base_url, args.admin_user, args.admin_password)
    print("  Token erhalten")
    print()

    # 2. Create realm
    print("[2/6] Realm erstellen...")
    get_or_create_realm(base_url, token, realm)
    print()

    # 3. Create groups
    print("[3/6] Gruppen erstellen...")
    admin_group_id = get_or_create_group(base_url, token, realm, "admin-users")
    standard_group_id = get_or_create_group(base_url, token, realm, "standard-users")
    set_default_group(base_url, token, realm, standard_group_id)
    print("  Default-Gruppe: standard-users")
    print()

    # 4. Create clients
    print("[4/6] Clients erstellen...")

    # Open WebUI (confidential client, authorization code flow)
    _, openwebui_secret = get_or_create_client(base_url, token, realm, {
        "clientId": "open-webui",
        "name": "Open WebUI",
        "protocol": "openid-connect",
        "publicClient": False,
        "directAccessGrantsEnabled": False,
        "standardFlowEnabled": True,
        "redirectUris": [f"https://webui.{args.base_domain}/oauth/oidc/callback"],
        "webOrigins": [f"https://webui.{args.base_domain}"],
        "defaultClientScopes": ["email", "profile"],
    })

    # BookStack (confidential client, authorization code flow)
    _, bookstack_secret = get_or_create_client(base_url, token, realm, {
        "clientId": "bookstack",
        "name": "BookStack Wiki",
        "protocol": "openid-connect",
        "publicClient": False,
        "directAccessGrantsEnabled": False,
        "standardFlowEnabled": True,
        "redirectUris": [f"https://bookstack.{args.base_domain}/oidc/callback"],
        "webOrigins": [f"https://bookstack.{args.base_domain}"],
        "defaultClientScopes": ["email", "profile"],
    })

    # oauth2-proxy (confidential client, used for ForwardAuth)
    _, proxy_secret = get_or_create_client(base_url, token, realm, {
        "clientId": "ancroo-proxy",
        "name": "Ancroo Forward Auth Proxy",
        "protocol": "openid-connect",
        "publicClient": False,
        "directAccessGrantsEnabled": False,
        "standardFlowEnabled": True,
        "redirectUris": [f"https://{auth_domain}/oauth2/callback"],
        "webOrigins": [f"https://*.{args.base_domain}"],
        "defaultClientScopes": ["email", "profile"],
    })
    print()

    # 5. Create admin user hint
    print("[5/6] Admin-Benutzer...")
    print(f"  Keycloak Admin: {args.admin_user} (Konsole: https://{auth_domain})")
    print(f"  Erstelle App-Admin ueber: ./module.sh sso add-user admin@{args.base_domain} --group admin-users")
    print()

    # 6. Summary
    print("[6/6] Setup abgeschlossen!")
    print()

    # Output secrets as KEY=VALUE for post-enable.sh to parse
    if openwebui_secret:
        print(f"OPEN_WEBUI_CLIENT_SECRET={openwebui_secret}")
    if bookstack_secret:
        print(f"BOOKSTACK_CLIENT_SECRET={bookstack_secret}")
    if proxy_secret:
        print(f"OAUTH2_PROXY_CLIENT_SECRET={proxy_secret}")


if __name__ == "__main__":
    main()
