cd ~/PeepogrobVPN && \
mkdir -p gradle/wrapper && \
cat > gradle/wrapper/gradle-wrapper.properties << 'EOF'
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=https\://services.gradle.org/distributions/gradle-8.2-bin.zip
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
EOF
wget -q "https://raw.githubusercontent.com/gradle/gradle/v8.2.0/gradle/wrapper/gradle-wrapper.jar" -O gradle/wrapper/gradle-wrapper.jar && \
cat > gradlew << 'GRADLEW'
#!/bin/sh
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec java -jar "$SCRIPT_DIR/gradle/wrapper/gradle-wrapper.jar" "$@"
GRADLEW
chmod +x gradlew && \
echo "=== WRAPPER OK ===" && \
ls -la gradle/wrapper/
