#!/usr/bin/env python3
"""
Keycloak Client Manager — Register/Unregister OAuth2 clients dynamically.

Called by sso-hook.sh when modules are enabled/disabled.

Usage:
    python3 keycloak-client-manager.py register \
        --admin-user admin --admin-password <pw> \
        --keycloak-url http://localhost:8080 --realm ancroo \
        --client-id ancroo --display-name "Ancroo AI" \
        --redirect-uri https://ancroo.example.com/callback \
        --sso-group standard-users

    python3 keycloak-client-manager.py unregister \
        --admin-user admin --admin-password <pw> \
        --keycloak-url http://localhost:8080 --realm ancroo \
        --client-id ancroo
"""
import argparse
import json
import sys
import urllib.request
import urllib.error
import urllib.parse


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


def register_client(base_url, token, realm, client_id, display_name,
                    redirect_uri, public_client=False):
    """Register a new OAuth2 client in Keycloak."""
    url = f"{base_url}/admin/realms/{realm}/clients"

    # Check if client already exists
    existing = api_request(f"{url}?clientId={client_id}", token=token) or []
    if existing:
        print(f"  Client '{client_id}' existiert bereits")
        client_uuid = existing[0]["id"]
    else:
        client_data = {
            "clientId": client_id,
            "name": display_name,
            "protocol": "openid-connect",
            "publicClient": public_client,
            "directAccessGrantsEnabled": False,
            "standardFlowEnabled": True,
            "redirectUris": [redirect_uri, f"{redirect_uri}/*"],
            # Keycloak 26+ uses "basic" instead of "openid" for the sub claim
            "defaultClientScopes": ["basic", "email", "profile", "roles", "web-origins"],
        }
        api_request(url, method="POST", token=token, data=client_data)
        existing = api_request(f"{url}?clientId={client_id}", token=token) or []
        if not existing:
            raise RuntimeError(f"Client '{client_id}' konnte nicht erstellt werden")
        client_uuid = existing[0]["id"]
        print(f"  Client '{client_id}' erstellt")

    # Add group membership mapper
    mapper_url = f"{url}/{client_uuid}/protocol-mappers/models"
    mappers = api_request(mapper_url, token=token) or []
    has_groups = any(m.get("name") == "groups" for m in mappers)

    if not has_groups:
        api_request(mapper_url, method="POST", token=token, data={
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

    # Get client secret for confidential clients
    if not public_client:
        secret_data = api_request(f"{url}/{client_uuid}/client-secret", token=token)
        if secret_data and secret_data.get("value"):
            print(f"  CLIENT_SECRET={secret_data['value']}")

    return client_uuid


def unregister_client(base_url, token, realm, client_id):
    """Remove an OAuth2 client from Keycloak."""
    url = f"{base_url}/admin/realms/{realm}/clients"
    existing = api_request(f"{url}?clientId={client_id}", token=token) or []

    if not existing:
        print(f"  Client '{client_id}' nicht gefunden — nichts zu tun")
        return

    client_uuid = existing[0]["id"]
    api_request(f"{url}/{client_uuid}", method="DELETE", token=token)
    print(f"  Client '{client_id}' entfernt")


def main():
    parser = argparse.ArgumentParser(description="Keycloak Client Manager")
    parser.add_argument("command", choices=["register", "unregister"])
    parser.add_argument("--admin-user", required=True)
    parser.add_argument("--admin-password", required=True)
    parser.add_argument("--keycloak-url", default="http://localhost:8080")
    parser.add_argument("--realm", default="ancroo")
    parser.add_argument("--client-id", required=True)
    parser.add_argument("--display-name", default="")
    parser.add_argument("--redirect-uri", default="")
    parser.add_argument("--sso-group", default="standard-users")
    parser.add_argument("--public-client", action="store_true")
    args = parser.parse_args()

    base_url = args.keycloak_url.rstrip("/")
    token = get_admin_token(base_url, args.admin_user, args.admin_password)

    if args.command == "register":
        if not args.redirect_uri:
            print("ERROR: --redirect-uri erforderlich fuer 'register'", file=sys.stderr)
            sys.exit(1)
        register_client(
            base_url, token, args.realm,
            args.client_id,
            args.display_name or args.client_id,
            args.redirect_uri,
            args.public_client,
        )
    elif args.command == "unregister":
        unregister_client(base_url, token, args.realm, args.client_id)


if __name__ == "__main__":
    main()
