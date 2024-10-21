#!/usr/bin/env bash
# debug
set -x

echo "Configuring Keycloak's Master realm $(date)"

echo "Initialize needed variables"
SERVICE_IP="localhost"
PORT="9090"
LOGIN_BANNER="Some dummy banner"

echo "loading keycloak user password from secret"
KEYCLOAK_USER="admin"
KEYCLOAK_PASSWORD="admin"

if [ -z "$KEYCLOAK_USER" ] || [ -z "$SERVICE_IP" ] || [ -z "$KEYCLOAK_PASSWORD" ]; then
    echo "Failed to initialize needed variables"
    exit 1
fi

echo "obtain access token for all admin operations"
mastertoken=$(curl -k -d "client_id=admin-cli" -d "username=${KEYCLOAK_USER}" -d "password=${KEYCLOAK_PASSWORD}" -d "grant_type=password" -d "client_secret=" https://${SERVICE_IP}:${PORT}/auth/realms/master/protocol/openid-connect/token | sed 's/.*access_token":"//g' | sed 's/".*//g')


echo "Update master-realm settings"

cat >/tmp/master-realm.json <<EOF
{"id": "master","realm": "master","accessTokenLifespan": 600,"enabled": true,"sslRequired": "all","bruteForceProtected": true,"loginTheme": "nokia-csf"}
EOF

OUT=$(curl -qSfsw '\n%{http_code}' -X PUT -k -H "Authorization: Bearer $mastertoken" https://${SERVICE_IP}:${PORT}/auth/admin/realms/master -H "Content-Type: application/json" --data @/tmp/master-realm.json) 2>/dev/null
RET=$?
if [[ $RET -ne 0 ]]; then
    echo "ret code is $RET"
    echo "HTTP Error: $(echo "$OUT" | tail -n1)"
    if [[ $(echo "$OUT" | tail -n1) -ne 409 ]]; then
        exit 1
    fi
fi

echo "Configure audit event settings"
cat >/tmp/events-config.json <<EOF
{"eventsEnabled":true,"eventsExpiration":60,"eventsListeners":["Audit Logging","jboss-logging"],"enabledEventTypes":["LOGIN","LOGIN_ERROR","REGISTER","REGISTER_ERROR","LOGOUT","LOGOUT_ERROR","CODE_TO_TOKEN","CODE_TO_TOKEN_ERROR","CLIENT_LOGIN","CLIENT_LOGIN_ERROR","FEDERATED_IDENTITY_LINK","FEDERATED_IDENTITY_LINK_ERROR","REMOVE_FEDERATED_IDENTITY","REMOVE_FEDERATED_IDENTITY_ERROR","UPDATE_EMAIL","UPDATE_EMAIL_ERROR","UPDATE_PROFILE","UPDATE_PROFILE_ERROR","UPDATE_PASSWORD","UPDATE_PASSWORD_ERROR","UPDATE_TOTP","UPDATE_TOTP_ERROR","VERIFY_EMAIL","VERIFY_EMAIL_ERROR","REMOVE_TOTP","REMOVE_TOTP_ERROR","GRANT_CONSENT","GRANT_CONSENT_ERROR","UPDATE_CONSENT","UPDATE_CONSENT_ERROR","REVOKE_GRANT","REVOKE_GRANT_ERROR","SEND_VERIFY_EMAIL","SEND_VERIFY_EMAIL_ERROR","SEND_RESET_PASSWORD","SEND_RESET_PASSWORD_ERROR","SEND_IDENTITY_PROVIDER_LINK","SEND_IDENTITY_PROVIDER_LINK_ERROR","RESET_PASSWORD","RESET_PASSWORD_ERROR","RESTART_AUTHENTICATION","RESTART_AUTHENTICATION_ERROR","IDENTITY_PROVIDER_LINK_ACCOUNT","IDENTITY_PROVIDER_LINK_ACCOUNT_ERROR","IDENTITY_PROVIDER_FIRST_LOGIN","IDENTITY_PROVIDER_FIRST_LOGIN_ERROR","IDENTITY_PROVIDER_POST_LOGIN","IDENTITY_PROVIDER_POST_LOGIN_ERROR","IMPERSONATE","IMPERSONATE_ERROR","CUSTOM_REQUIRED_ACTION","CUSTOM_REQUIRED_ACTION_ERROR","EXECUTE_ACTIONS","EXECUTE_ACTIONS_ERROR","EXECUTE_ACTION_TOKEN","EXECUTE_ACTION_TOKEN_ERROR","CLIENT_REGISTER","CLIENT_REGISTER_ERROR","CLIENT_UPDATE","CLIENT_UPDATE_ERROR","CLIENT_DELETE","CLIENT_DELETE_ERROR","CLIENT_INITIATED_ACCOUNT_LINKING","CLIENT_INITIATED_ACCOUNT_LINKING_ERROR","TOKEN_EXCHANGE","TOKEN_EXCHANGE_ERROR","PERMISSION_TOKEN"],"adminEventsEnabled":false,"adminEventsDetailsEnabled":false}
EOF

OUT=$(curl -qSfsw '\n%{http_code}' -X PUT -k -H "Authorization: Bearer $mastertoken" https://${SERVICE_IP}:${PORT}/auth/admin/realms/master/events/config -H "Content-Type: application/json" --data @/tmp/events-config.json) 2>/dev/null
RET=$?
if [[ $RET -ne 0 ]]; then
    echo "ret code is $RET"
    echo "HTTP Error: $(echo "$OUT" | tail -n1)"
    if [[ $(echo "$OUT" | tail -n1) -ne 409 ]]; then
        exit 1
    fi
fi

echo "fetch access_token after changing the token lifespan"
mastertoken=$(curl -k -d "client_id=admin-cli" -d "username=${KEYCLOAK_USER}" -d "password=${KEYCLOAK_PASSWORD}" -d "grant_type=password" -d "client_secret=" https://${SERVICE_IP}:${PORT}/auth/realms/master/protocol/openid-connect/token | sed 's/.*access_token":"//g' | sed 's/".*//g')

echo "extract clientid"
clientid=$(curl -k -H "Authorization: Bearer $mastertoken" https://${SERVICE_IP}:${PORT}/auth/admin/realms/master/clients?clientId=admin-cli | awk -F'[,:]' '/"id":.*?[^\\]"/{print $2; exit}' | tr -d '\"')

if [ -z "$clientid" ]; then
    echo "Failed to extract client id"
    exit 1
fi

#create the mappers to insert additional information into access token generated for admin-cli client.
cat >/tmp/audmap.json <<EOF
{"name": "aud mapper","protocol": "openid-connect","protocolMapper": "oidc-audience-mapper","consentRequired": false,"config": {"included.client.audience": "admin-cli","id.token.claim": "true","access.token.claim": "true"}}
EOF
cat >/tmp/rolemap.json <<EOF
{"name":"role mapper","protocol":"openid-connect","protocolMapper":"oidc-usermodel-realm-role-mapper","consentRequired":false,"config":{"id.token.claim":"true","access.token.claim":"true","claim.name":"role","jsonType.label":"String","userinfo.token.claim":"true"}}
EOF
cat >/tmp/groupmap.json <<EOF
{"name":"group mapper","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","consentRequired":false,"config":{"id.token.claim":"true","access.token.claim":"true","claim.name":"groups","userinfo.token.claim":"true"}}
EOF
echo "Create imsettings mapper"
cat >/tmp/imsettings.json <<EOF
{"name": "audience mapper","protocol": "openid-connect","protocolMapper": "oidc-audience-mapper","consentRequired": false,"config": {"included.client.audience": "aifintegration-client","id.token.claim": "false","access.token.claim": "true"}}
EOF
cat >/tmp/audwebclientmap.json <<EOF
{"name": "aud webclient mapper","protocol": "openid-connect","protocolMapper": "oidc-audience-mapper","consentRequired": false,"config": {"included.client.audience": "webclient","id.token.claim": "true","access.token.claim": "true"}}
EOF
cat >/tmp/groupwebclientmap.json <<EOF
{"name":"group webclient mapper","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","consentRequired":false,"config":{"id.token.claim":"true","access.token.claim":"true","claim.name":"groups","userinfo.token.claim":"true"}}
EOF

echo "Create group mapper"
OUT=$(curl -k -qSfsw '\n%{http_code}' -H "Authorization: Bearer $mastertoken" https://${SERVICE_IP}:${PORT}/auth/admin/realms/master/clients/$clientid/protocol-mappers/models -H "Content-Type: application/json" --data @/tmp/groupmap.json) 2>/dev/null
RET=$?
if [[ $RET -ne 0 ]]; then
    echo "ret code is $RET"
    echo "HTTP Error: $(echo "$OUT" | tail -n1)"
    if [[ $(echo "$OUT" | tail -n1) -ne 409 ]]; then
        exit 1
    fi
fi

echo "Create rolemapper"
OUT=$(curl -k -qSfsw '\n%{http_code}' -H "Authorization: Bearer $mastertoken" https://${SERVICE_IP}:${PORT}/auth/admin/realms/master/clients/$clientid/protocol-mappers/models -H "Content-Type: application/json" --data @/tmp/rolemap.json) 2>/dev/null
RET=$?
if [[ $RET -ne 0 ]]; then
    echo "ret code is $RET"
    echo "HTTP Error: $(echo "$OUT" | tail -n1)"
    if [[ $(echo "$OUT" | tail -n1) -ne 409 ]]; then
        exit 1
    fi
fi

echo "Create audience mapper"
OUT=$(curl -k -qSfsw '\n%{http_code}' -H "Authorization: Bearer $mastertoken" https://${SERVICE_IP}:${PORT}/auth/admin/realms/master/clients/$clientid/protocol-mappers/models -H "Content-Type: application/json" --data @/tmp/audmap.json) 2>/dev/null
RET=$?
if [[ $RET -ne 0 ]]; then
    echo "ret code is $RET"
    echo "HTTP Error: $(echo "$OUT" | tail -n1)"
    if [[ $(echo "$OUT" | tail -n1) -ne 409 ]]; then
        exit 1
    fi
fi

echo "Enable full scope for admin-cli client"
cat >/tmp/admin-cli.json <<EOF
{"clientId": "admin-cli","enabled": true,"fullScopeAllowed":true}
EOF
OUT=$(curl -qSfsw '\n%{http_code}' -X PUT -k -H "Authorization: Bearer $mastertoken" https://${SERVICE_IP}:${PORT}/auth/admin/realms/master/clients/$clientid -H "Content-Type: application/json" --data @/tmp/admin-cli.json) 2>/dev/null
RET=$?
if [[ $RET -ne 0 ]]; then
    echo "ret code is $RET"
    echo "HTTP Error: $(echo "$OUT" | tail -n1)"
    if [[ $(echo "$OUT" | tail -n1) -ne 409 ]]; then
        exit 1
    fi
fi

echo "create nss-client" #=> to be used by ZTS NSS module
cat >/tmp/clientmodel.json <<EOF
{"clientId": "nss-client","enabled": true,"publicClient": false,"secret": "abcd","serviceAccountsEnabled": true,"protocol": "openid-connect","access": {"view": true,"configure": true}}
EOF
OUT=$(curl -qSfsw '\n%{http_code}' -k -H "Authorization: Bearer $mastertoken" https://${SERVICE_IP}:${PORT}/auth/admin/realms/master/clients -H "Content-Type: application/json" --data @/tmp/clientmodel.json) 2>/dev/null
RET=$?
if [[ $RET -ne 0 ]]; then
    echo "ret code is $RET"
    echo "HTTP Error: $(echo "$OUT" | tail -n1)"
    if [[ $(echo "$OUT" | tail -n1) -ne 409 ]]; then
        exit 1
    fi
fi
echo "assign the permission 'view-users' to the client"
clientid=$(curl -k -H "Authorization: Bearer $mastertoken" https://${SERVICE_IP}:${PORT}/auth/admin/realms/master/clients?clientId=master-realm | awk -F'[,:]' '/"id":.*?[^\\]"/{print $2; exit}' | tr -d '\"')

if [ -z "$clientid" ]; then
    echo "Failed to extract client id"
    exit 1
fi
userid=$(curl -k -H "Authorization: bearer $mastertoken" https://${SERVICE_IP}:${PORT}/auth/admin/realms/master/users?username=service-account-nss-client | awk -F'[,:]' '/"id":.*?[^\\]"/{print $2; exit}' | tr -d '\"')

if [ -z "$userid" ]; then
    echo "Failed to extract user id"
    exit 1
fi
echo -n '[' >/tmp/roledef.json
curl -k -H "Authorization: bearer $mastertoken" https://${SERVICE_IP}:${PORT}/auth/admin/realms/master/clients/$clientid/roles/view-users >>/tmp/roledef.json
echo -n ']' >>/tmp/roledef.json
OUT=$(curl -qSfsw '\n%{http_code}' -k -H "Authorization: bearer $mastertoken" https://${SERVICE_IP}:${PORT}/auth/admin/realms/master/users/$userid/role-mappings/clients/$clientid -H "Content-Type: application/json" --data @/tmp/roledef.json) 2>/dev/null
RET=$?
if [[ $RET -ne 0 ]]; then
    echo "ret code is $RET"
    echo "HTTP Error: $(echo "$OUT" | tail -n1)"
    if [[ $(echo "$OUT" | tail -n1) -ne 409 ]]; then
        exit 1
    fi
fi

echo "create aifintegration-client" #=> to be used by ZTS IM module
cat >/tmp/clientmodelIM.json <<EOF
{"clientId": "aifintegration-client","enabled": true,"publicClient": false,"serviceAccountsEnabled": true,"protocol": "openid-connect","access": {"view": true,"configure": true}}
EOF
OUT=$(curl -qSfsw '\n%{http_code}' -k -H "Authorization: Bearer $mastertoken" https://${SERVICE_IP}:${PORT}/auth/admin/realms/master/clients -H "Content-Type: application/json" --data @/tmp/clientmodelIM.json) 2>/dev/null
RET=$?
if [[ $RET -ne 0 ]]; then
    echo "ret code is $RET"
    echo "HTTP Error: $(echo "$OUT" | tail -n1)"
    if [[ $(echo "$OUT" | tail -n1) -ne 409 ]]; then
        exit 1
    fi
fi

echo "Create audience mapper for imsettings"
imsettingsclientid=$(curl -k -H "Authorization: Bearer $mastertoken" https://${SERVICE_IP}:${PORT}/auth/admin/realms/master/clients?clientId=aifintegration-client | awk -F'[,:]' '/"id":.*?[^\\]"/{print $2; exit}' | tr -d '\"')

if [ -z "$imsettingsclientid" ]; then
    echo "Failed to extract imsettings client id"
    exit 1
fi

OUT=$(curl -k -qSfsw '\n%{http_code}' -H "Authorization: Bearer $mastertoken" https://${SERVICE_IP}:${PORT}/auth/admin/realms/master/clients/$imsettingsclientid/protocol-mappers/models -H "Content-Type: application/json" --data @/tmp/imsettings.json) 2>/dev/null
RET=$?
if [[ $RET -ne 0 ]]; then
    echo "ret code is $RET"
    echo "HTTP Error: $(echo "$OUT" | tail -n1)"
    if [[ $(echo "$OUT" | tail -n1) -ne 409 ]]; then
        exit 1
    fi
fi

echo "Done configuring master realm $(date)"

exit 0

