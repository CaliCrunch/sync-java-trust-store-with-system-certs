#!/usr/bin/env bash
set -euo pipefail

# =====================================================================
# Usage:
#   ./fix-java-trust.sh           # Fix/sync trust store
#   ./fix-java-trust.sh --restore # Restore original cacerts
# =====================================================================

# ----------- CONFIG ------------
STORE_PASS="changeit"
SYSTEM_STORE="/etc/ssl/certs/java/cacerts"
RESTORE_MODE=false
STEP=""

# ----------- UTILS -------------
step() {
  STEP="$1"
  echo
  echo "======================================================================="
  echo "STEP: $STEP"
  echo "======================================================================="
}

info()  { echo "   [INFO]  $*"; }
ok()    { echo "   [ OK ]  $*"; }
warn()  { echo "   [WARN]  $*"; }
fail()  { echo "   [FAIL]  $*" >&2; exit 1; }

# ----------- FLAGS -------------
if [[ "${1:-}" == "--restore" ]]; then
  RESTORE_MODE=true
fi

# ----------- DETECT JAVA_HOME -----------
step "Detecting Java environment"
if [ -z "${JAVA_HOME:-}" ]; then
  JAVA_BIN=$(readlink -f "$(command -v java)" 2>/dev/null || true)
  if [ -n "$JAVA_BIN" ]; then
    JAVA_HOME=$(dirname "$(dirname "$JAVA_BIN")")
    info "Detected JAVA_HOME: $JAVA_HOME"
  else
    fail "No JAVA_HOME found. Please ensure Java is installed and on PATH."
  fi
else
  info "Using JAVA_HOME: $JAVA_HOME"
fi

if [ ! -x "$JAVA_HOME/bin/java" ]; then
  fail "JAVA_HOME is invalid: $JAVA_HOME"
fi

JDK_CACERTS="$JAVA_HOME/lib/security/cacerts"
BACKUP_PATH="$JDK_CACERTS.bak"
KEYTOOL_PATH="$(readlink -f "$JAVA_HOME/bin/keytool" 2>/dev/null || true)"
[ -x "$KEYTOOL_PATH" ] || fail "keytool not found under $JAVA_HOME/bin"

# =====================================================================
# RESTORE MODE
# =====================================================================
if [ "$RESTORE_MODE" = true ]; then
  step "Restoring from backup"
  if [ -f "$BACKUP_PATH" ]; then
    info "Restoring original cacerts from $BACKUP_PATH..."
    sudo rm -f "$JDK_CACERTS"
    sudo cp "$BACKUP_PATH" "$JDK_CACERTS"
    ok "Restored $JDK_CACERTS"
  else
    fail "No backup found at $BACKUP_PATH. Nothing to restore."
  fi
  exit 0
fi

# =====================================================================
# FIX / SYNC MODE
# =====================================================================

step "Preparing environment"
if ! dpkg -s ca-certificates-java >/dev/null 2>&1; then
  info "Installing ca-certificates-java..."
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates-java
else
  info "ca-certificates-java already installed"
fi

sudo mkdir -p /usr/lib/jvm
sudo mkdir -p "$(dirname "$SYSTEM_STORE")"

if [[ "$JAVA_HOME" == *".sdkman"* ]]; then
  info "Registering SDKMAN JDK under /usr/lib/jvm/sdkman-java"
  sudo ln -sf "$JAVA_HOME" /usr/lib/jvm/sdkman-java
fi

# =====================================================================
step "Building new Java trust store"
sudo rm -f "$SYSTEM_STORE"

info "Generating placeholder base keystore..."
sudo "$KEYTOOL_PATH" -genkey \
  -alias temp \
  -keystore "$SYSTEM_STORE" \
  -storepass "$STORE_PASS" \
  -keyalg RSA -keysize 2048 \
  -dname "CN=temp" -noprompt >/dev/null

info "Removing placeholder entry..."
sudo "$KEYTOOL_PATH" -delete \
  -alias temp \
  -keystore "$SYSTEM_STORE" \
  -storepass "$STORE_PASS" >/dev/null 2>&1 || true

info "Importing all system certificates..."
COUNT=0
for cert in /usr/local/share/ca-certificates/*.crt /etc/ssl/certs/*.pem; do
  if [ -f "$cert" ]; then
    sudo "$KEYTOOL_PATH" -importcert \
      -trustcacerts \
      -file "$cert" \
      -alias "$(basename "$cert")" \
      -keystore "$SYSTEM_STORE" \
      -storepass "$STORE_PASS" \
      -noprompt >/dev/null 2>&1 || true
    ((COUNT++))
  fi
done
ok "Imported $COUNT certificates"

# =====================================================================
step "Converting PKCS12 to JKS (for JVM compatibility)"
TYPE=$("$KEYTOOL_PATH" -list -keystore "$SYSTEM_STORE" \
  -storepass "$STORE_PASS" 2>&1 | grep "Keystore type" || true)
if [[ "$TYPE" == *"PKCS12"* ]]; then
  info "Converting trust store format..."
  sudo "$KEYTOOL_PATH" -importkeystore \
    -srckeystore "$SYSTEM_STORE" \
    -srcstoretype PKCS12 \
    -srcstorepass "$STORE_PASS" \
    -destkeystore "${SYSTEM_STORE}.jks" \
    -deststoretype JKS \
    -deststorepass "$STORE_PASS" >/dev/null
  sudo mv "${SYSTEM_STORE}.jks" "$SYSTEM_STORE"
  ok "Converted to JKS format"
else
  info "Already in JKS format"
fi

sudo chmod 644 "$SYSTEM_STORE"
sudo chown root:root "$SYSTEM_STORE"

# =====================================================================
step "Linking Java to system trust store"
if [ -f "$JDK_CACERTS" ] && [ ! -h "$JDK_CACERTS" ]; then
  info "Backing up existing JDK cacerts to $BACKUP_PATH"
  cp "$JDK_CACERTS" "$BACKUP_PATH"
fi

sudo rm -f "$JDK_CACERTS"
sudo ln -s "$SYSTEM_STORE" "$JDK_CACERTS"
ok "Linked $JDK_CACERTS to $SYSTEM_STORE"

# =====================================================================
step "Verifying Java trust store"
CERT_COUNT=$(sudo "$KEYTOOL_PATH" -list \
  -keystore "$SYSTEM_STORE" \
  -storepass "$STORE_PASS" 2>/dev/null | grep -c "trustedCertEntry" || true)

if [ "$CERT_COUNT" -gt 0 ]; then
  ok "Java trust store contains $CERT_COUNT certificates"
else
  warn "Trust store appears empty. Check $SYSTEM_STORE"
fi

echo
echo "======================================================================="
ok "Java trust synchronization complete!"
echo "======================================================================="
echo

