#!/usr/bin/env bash
# Configure a fresh Keycloak realm for the Urchin OAuth example.
#
# Run AFTER `docker compose up -d`, from this directory. Requires docker and python3 on
# the host. Idempotent it is not: run it once against a fresh Keycloak.
#
# It creates:
#   - realm "mcp" (issuer http://localhost:8080/realms/mcp)
#   - client scopes notes:read / notes:write, each with two Audience mappers so every
#     token names the MCP resource (RFC 8707) and the introspection client. Keycloak does
#     not honor the OAuth `resource` parameter, so the audience must be injected this way.
#   - a confidential client "mcp-resource-server" that the server uses to introspect tokens
#   - a public client "mcp-inspector" (PKCE) for the MCP Inspector / curl tests
#   - a test user alice / password
#   - removal of the anonymous Trusted Hosts client-registration policy, so the MCP
#     Inspector's Dynamic Client Registration from localhost is allowed (DEV-ONLY).
set -euo pipefail

KC_CONTAINER="${KC_CONTAINER:-keycloak}"
REALM="${REALM:-mcp}"
RESOURCE="http://localhost:4000/mcp"
RS_CLIENT="mcp-resource-server"
RS_SECRET="mcp-resource-server-secret"

kc() { docker exec "$KC_CONTAINER" /opt/keycloak/bin/kcadm.sh "$@"; }
csid() {
  docker exec "$KC_CONTAINER" /opt/keycloak/bin/kcadm.sh get client-scopes -r "$REALM" --fields id,name |
    python3 -c 'import sys,json;n=sys.argv[1];print(next(c["id"] for c in json.load(sys.stdin) if c["name"]==n))' "$1"
}

command -v python3 >/dev/null || {
  echo "python3 is required" >&2
  exit 1
}

echo "Waiting for Keycloak..."
for _ in $(seq 1 60); do
  if curl -sf -o /dev/null http://localhost:8080/realms/master/.well-known/openid-configuration; then break; fi
  sleep 2
done

kc config credentials --server http://localhost:8080 --realm master --user admin --password admin

# Dev realm: relaxed SSL and a longer login timeout for unhurried manual testing.
kc create realms -s realm="$REALM" -s enabled=true -s sslRequired=NONE \
  -s accessCodeLifespanLogin=1800 -s accessCodeLifespanUserAction=1800

for s in notes:read notes:write; do
  kc create client-scopes -r "$REALM" -s name="$s" -s protocol=openid-connect \
    -s 'attributes."include.in.token.scope"=true' \
    -s 'attributes."display.on.consent.screen"=true'
  sid=$(csid "$s")
  kc create client-scopes/"$sid"/protocol-mappers/models -r "$REALM" \
    -s name=mcp-audience -s protocol=openid-connect -s protocolMapper=oidc-audience-mapper \
    -s "config.\"included.custom.audience\"=$RESOURCE" \
    -s 'config."access.token.claim"=true' -s 'config."id.token.claim"=false'
  # Required, not redundant: Keycloak's introspection returns active=false unless the
  # introspecting client is itself in the token's aud, so name mcp-resource-server here too.
  kc create client-scopes/"$sid"/protocol-mappers/models -r "$REALM" \
    -s name=introspection-audience -s protocol=openid-connect -s protocolMapper=oidc-audience-mapper \
    -s "config.\"included.client.audience\"=$RS_CLIENT" \
    -s 'config."access.token.claim"=true' -s 'config."id.token.claim"=false'
  # Make it a realm default so the pre-registered Inspector client carries it.
  kc update default-default-client-scopes/"$sid" -r "$REALM"
done

# Confidential client the resource server authenticates with to introspect tokens.
kc create clients -r "$REALM" -s clientId="$RS_CLIENT" -s enabled=true \
  -s publicClient=false -s standardFlowEnabled=false -s directAccessGrantsEnabled=false \
  -s serviceAccountsEnabled=false -s secret="$RS_SECRET"

# Public client for the MCP Inspector. Also has direct grant enabled so the README's
# curl examples can mint a token without a browser.
kc create clients -r "$REALM" -s clientId=mcp-inspector -s enabled=true \
  -s publicClient=true -s standardFlowEnabled=true -s directAccessGrantsEnabled=true \
  -s 'attributes."pkce.code.challenge.method"=S256' \
  -s 'redirectUris=["http://localhost:6274/oauth/callback","http://localhost:6274/oauth/callback/debug"]' \
  -s 'webOrigins=["http://localhost:6274"]'

# Make notes:write optional (not default) on this client so the README's curl examples can
# mint a read-only token and show scope enforcement. The Inspector uses its own
# dynamically-registered client and requests notes:write itself during the OAuth flow.
ins=$(kc get clients -r "$REALM" -q clientId=mcp-inspector --fields id --format csv --noquotes | head -1)
nw=$(csid notes:write)
kc delete clients/"$ins"/default-client-scopes/"$nw" -r "$REALM"
kc update clients/"$ins"/optional-client-scopes/"$nw" -r "$REALM"

# Allow the Inspector's anonymous Dynamic Client Registration from localhost.
th=$(kc get components -r "$REALM" \
  -q type=org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy |
  python3 -c 'import sys,json;print(next((c["id"] for c in json.load(sys.stdin) if c.get("providerId")=="trusted-hosts" and c.get("subType")=="anonymous"), ""))')
[ -n "$th" ] && kc delete components/"$th" -r "$REALM"

kc create users -r "$REALM" -s username=alice -s enabled=true -s email=alice@example.com \
  -s emailVerified=true -s firstName=Alice -s lastName=Example
kc set-password -r "$REALM" --username alice --new-password password

echo "Realm '$REALM' ready. Login: alice / password"
