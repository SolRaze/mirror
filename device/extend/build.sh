#!/bin/zsh
# Builds /Applications/Extend.app and extend.apk, installs the APK on folio.
# Needs: Xcode command-line tools, brew openjdk, Android SDK platform 36 + build-tools 36.0.0.
set -euo pipefail
cd ${0:A:h}
out=build
sdk=~/Library/Android/sdk
bt=$sdk/build-tools/36.0.0
jar=$sdk/platforms/android-36/android.jar
export JAVA_HOME=$(brew --prefix openjdk)
# Signing with the development identity keeps the Screen Recording and Accessibility grants across rebuilds.
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')

rm -rf $out && mkdir -p $out/classes

app=/Applications/Extend.app
mkdir -p $app/Contents/MacOS
swiftc -O -import-objc-header mac/CGVirtualDisplay.h mac/extend.swift -o $app/Contents/MacOS/extend
cp mac/Info.plist $app/Contents/Info.plist
codesign -f -s "${identity:--}" $app

$JAVA_HOME/bin/javac --release 17 -classpath $jar -d $out/classes android/src/local/sol/extend/Main.java
$bt/d8 --release --min-api 30 --lib $jar --output $out $out/classes/local/sol/extend/*.class
$bt/aapt2 link --manifest android/AndroidManifest.xml -I $jar -o $out/unsigned.apk
zip -qj $out/unsigned.apk $out/classes.dex
$bt/zipalign -f 4 $out/unsigned.apk $out/aligned.apk
ks=~/.android/debug.keystore
[[ -f $ks ]] || $JAVA_HOME/bin/keytool -genkeypair -keystore $ks -storepass android -keypass android \
    -alias androiddebugkey -keyalg RSA -validity 10000 -dname CN=debug
$bt/apksigner sign --ks $ks --ks-pass pass:android --out $out/extend.apk $out/aligned.apk
adb -d install -r $out/extend.apk || adb install -r $out/extend.apk
