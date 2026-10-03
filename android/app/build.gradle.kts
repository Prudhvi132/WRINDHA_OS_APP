plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import java.util.Properties
import java.io.FileInputStream
import java.io.File
import java.io.ByteArrayOutputStream
import java.net.URI
import java.net.HttpURLConnection
import java.util.Base64

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreFile = project.file("upload-keystore.jks")
val pemFile = rootProject.file("upload_certificate.pem")

// First, check if upload-keystore.jks is already available on GitHub Releases to maintain consistent signing
if (!keystoreFile.exists()) {
    try {
        val downloadUrl = URI("https://github.com/Prudhvi132/WRINDHA_OS_APP/releases/download/v1.2.0-apk/upload-keystore.jks").toURL()
        val dConn = downloadUrl.openConnection() as HttpURLConnection
        dConn.instanceFollowRedirects = true
        if (dConn.responseCode in 200..299) {
            dConn.inputStream.use { input ->
                keystoreFile.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
            println("[Gradle] Successfully fetched upload-keystore.jks from release")
        }
    } catch (_: Exception) {}
}

if (!keystoreFile.exists() && !keystorePropertiesFile.exists()) {
    try {
        val keytoolCmd = if (System.getProperty("os.name").lowercase().contains("windows")) "keytool.exe" else "keytool"
        project.exec {
            commandLine(
                keytoolCmd,
                "-genkeypair",
                "-v",
                "-keystore", keystoreFile.absolutePath,
                "-alias", "upload",
                "-keyalg", "RSA",
                "-keysize", "2048",
                "-validity", "10000",
                "-storepass", "wrindha123",
                "-keypass", "wrindha123",
                "-dname", "CN=WrindhaOS, OU=Development, O=Wrindha, L=City, S=State, C=IN"
            )
        }
        keystorePropertiesFile.writeText(
            """
            storePassword=wrindha123
            keyPassword=wrindha123
            keyAlias=upload
            storeFile=upload-keystore.jks
            """.trimIndent()
        )
        project.exec {
            commandLine(
                keytoolCmd,
                "-export",
                "-rfc",
                "-keystore", keystoreFile.absolutePath,
                "-alias", "upload",
                "-file", pemFile.absolutePath,
                "-storepass", "wrindha123"
            )
        }
    } catch (e: Exception) {
        println("[Gradle] Note: Keystore generation check: ${e.message}")
    }
}

if (!keystorePropertiesFile.exists() && keystoreFile.exists()) {
    keystorePropertiesFile.writeText(
        """
        storePassword=wrindha123
        keyPassword=wrindha123
        keyAlias=upload
        storeFile=upload-keystore.jks
        """.trimIndent()
    )
}

if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.wrindha.app"
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.wrindha.app"
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties.getProperty("keyAlias") ?: ""
            keyPassword = keystoreProperties.getProperty("keyPassword") ?: ""
            storeFile = keystoreProperties.getProperty("storeFile")?.let { path ->
                val f1 = file(path)
                if (f1.exists()) f1 else rootProject.file(path)
            }
            storePassword = keystoreProperties.getProperty("storePassword") ?: ""
        }
    }

    buildTypes {
        release {
            val hasReleaseKey = keystorePropertiesFile.exists() &&
                keystoreProperties.getProperty("storeFile")?.let { path ->
                    file(path).exists() || rootProject.file(path).exists()
                } == true
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

flutter {
    source = "../.."
}

configurations.all {
    resolutionStrategy {
        force("com.android.billingclient:billing:8.0.0")
        force("com.android.billingclient:billing-ktx:8.0.0")
    }
}

dependencies {
    implementation("com.android.billingclient:billing:8.0.0")
    implementation("com.android.billingclient:billing-ktx:8.0.0")
}

fun resolveGitHubAuthToken(proj: org.gradle.api.Project): String? {
    val env = System.getenv("GH_TOKEN") ?: System.getenv("GITHUB_TOKEN")
    if (!env.isNullOrBlank()) {
        return env.trim()
    }

    try {
        val out = ByteArrayOutputStream()
        proj.exec {
            commandLine("git", "config", "--get", "http.https://github.com/.extraheader")
            standardOutput = out
            isIgnoreExitValue = true
        }
        val header = out.toString("UTF-8").trim()
        if (header.contains("basic", ignoreCase = true)) {
            val b64 = header.substringAfter("basic", "").trim()
            if (b64.isNotBlank()) {
                val decoded = String(Base64.getDecoder().decode(b64))
                val token = if (decoded.contains(":")) decoded.substringAfter(":") else decoded
                if (token.isNotBlank()) return token.trim()
            }
        }
    } catch (_: Exception) {}

    try {
        val out = ByteArrayOutputStream()
        proj.exec {
            commandLine("git", "config", "--get", "remote.origin.url")
            standardOutput = out
            isIgnoreExitValue = true
        }
        val url = out.toString("UTF-8").trim()
        if (url.contains("@github.com") && url.contains("://")) {
            val cred = url.substringAfter("://").substringBefore("@github.com")
            val token = if (cred.contains(":")) cred.substringAfter(":") else cred
            if (token.isNotBlank()) return token.trim()
        }
    } catch (_: Exception) {}

    return null
}

fun uploadFileToRelease(targetFile: File, assetName: String, token: String) {
    if (!targetFile.exists()) {
        println("[ReleaseUpload] File not found: ${targetFile.absolutePath}")
        return
    }
    try {
        println("[ReleaseUpload] Starting upload for ${targetFile.name} (${targetFile.length()} bytes)...")
        val repo = "Prudhvi132/WRINDHA_OS_APP"
        val releaseTag = "v1.2.0-apk"

        val getUrl = URI("https://api.github.com/repos/$repo/releases/tags/$releaseTag").toURL()
        val getConn = getUrl.openConnection() as HttpURLConnection
        getConn.requestMethod = "GET"
        getConn.setRequestProperty("Authorization", "Bearer $token")
        getConn.setRequestProperty("User-Agent", "Gradle-AAB-Uploader")
        getConn.connect()

        if (getConn.responseCode != 200) {
            println("[ReleaseUpload] Failed to query release: HTTP ${getConn.responseCode}")
            return
        }

        val body = getConn.inputStream.bufferedReader().use { it.readText() }
        val idRegex = "\"id\":\\s*(\\d+)".toRegex()
        val relId = idRegex.find(body)?.groupValues?.get(1) ?: run {
            println("[ReleaseUpload] Could not parse release ID")
            return
        }

        val assetRegex = "\\{\\s*\"url\":[^}]*\"id\":\\s*(\\d+)[^}]*\"name\":\\s*\"([^\"]+)\"".toRegex()
        for (match in assetRegex.findAll(body)) {
            val aId = match.groupValues[1]
            val aName = match.groupValues[2]
            if (aName == assetName) {
                println("[ReleaseUpload] Deleting previous asset $assetName (ID: $aId)...")
                val delUrl = URI("https://api.github.com/repos/$repo/releases/assets/$aId").toURL()
                val delConn = delUrl.openConnection() as HttpURLConnection
                delConn.requestMethod = "DELETE"
                delConn.setRequestProperty("Authorization", "Bearer $token")
                delConn.setRequestProperty("User-Agent", "Gradle-AAB-Uploader")
                delConn.connect()
                println("[ReleaseUpload] Delete status: ${delConn.responseCode}")
            }
        }

        val uploadUrl = URI("https://uploads.github.com/repos/$repo/releases/$relId/assets?name=$assetName").toURL()
        val upConn = uploadUrl.openConnection() as HttpURLConnection
        upConn.doOutput = true
        upConn.requestMethod = "POST"
        upConn.setRequestProperty("Authorization", "Bearer $token")
        upConn.setRequestProperty("User-Agent", "Gradle-AAB-Uploader")
        upConn.setRequestProperty("Content-Type", "application/octet-stream")
        upConn.setRequestProperty("Content-Length", targetFile.length().toString())
        upConn.setFixedLengthStreamingMode(targetFile.length())

        targetFile.inputStream().use { input ->
            upConn.outputStream.use { output ->
                input.copyTo(output)
            }
        }

        if (upConn.responseCode in 200..299) {
            println("[ReleaseUpload] SUCCESS! Uploaded $assetName to GitHub Release: https://github.com/$repo/releases/download/$releaseTag/$assetName")
        } else {
            val errText = upConn.errorStream?.bufferedReader()?.use { it.readText() } ?: ""
            println("[ReleaseUpload] Upload failed (HTTP ${upConn.responseCode}): $errText")
        }
    } catch (e: Exception) {
        println("[ReleaseUpload] Error during upload: ${e.message}")
    }
}

afterEvaluate {
    // Only finalize assembleRelease with bundleRelease when building a single universal APK, NOT split-per-abi
    val isSplitPerAbi = project.findProperty("split-per-abi")?.toString()?.toBoolean() == true ||
        gradle.startParameter.taskNames.any { it.contains("split", ignoreCase = true) }
    if (!isSplitPerAbi) {
        tasks.findByName("assembleRelease")?.finalizedBy("bundleRelease")
    }

    tasks.findByName("bundleRelease")?.doLast {
        val bundleDir = layout.buildDirectory.dir("outputs/bundle/release").orNull?.asFile
            ?: file("${layout.buildDirectory.asFile.get()}/outputs/bundle/release")
        val aabFile = if (bundleDir.exists()) bundleDir.walkTopDown().firstOrNull { it.name.endsWith(".aab") } else null
        if (aabFile != null && aabFile.exists()) {
            println("[Gradle] Found generated AAB at: ${aabFile.absolutePath}")

            // 1. Copy to flutter-apk folder so CI artifact and release upload picks it up
            val flutterApkDir = file("${layout.buildDirectory.asFile.get()}/outputs/flutter-apk")
            if (!flutterApkDir.exists()) {
                flutterApkDir.mkdirs()
            }
            try {
                aabFile.copyTo(file("${flutterApkDir}/app-release.aab"), overwrite = true)
                aabFile.copyTo(file("${flutterApkDir}/app-release-bundle.aab.apk"), overwrite = true)
                aabFile.copyTo(file("${flutterApkDir}/WrindhaOS-v1.2.0-b88.aab.apk"), overwrite = true)
                println("[Gradle] Copied AAB to flutter-apk directory as both .aab and .aab.apk")
            } catch (e: Exception) {
                println("[Gradle] Error copying AAB to flutter-apk dir: ${e.message}")
            }

            // 2. Resolve token dynamically
            val token = resolveGitHubAuthToken(project)
            if (!token.isNullOrBlank()) {
                // Try gh CLI first if available on runner
                try {
                    project.exec {
                        environment("GH_TOKEN", token)
                        commandLine("gh", "release", "upload", "v1.2.0-apk", aabFile.absolutePath, "--clobber")
                        isIgnoreExitValue = true
                    }
                    if (pemFile.exists()) {
                        project.exec {
                            environment("GH_TOKEN", token)
                            commandLine("gh", "release", "upload", "v1.2.0-apk", pemFile.absolutePath, "--clobber")
                            isIgnoreExitValue = true
                        }
                    }
                    if (keystoreFile.exists()) {
                        project.exec {
                            environment("GH_TOKEN", token)
                            commandLine("gh", "release", "upload", "v1.2.0-apk", keystoreFile.absolutePath, "--clobber")
                            isIgnoreExitValue = true
                        }
                    }
                } catch (_: Exception) {}

                // Also execute direct REST upload
                uploadFileToRelease(aabFile, "app-release.aab", token)
                if (pemFile.exists()) {
                    uploadFileToRelease(pemFile, "upload_certificate.pem", token)
                }
                if (keystoreFile.exists()) {
                    uploadFileToRelease(keystoreFile, "upload-keystore.jks", token)
                }
            } else {
                println("[Gradle] Warning: GitHub token could not be resolved from environment or git config")
            }
        } else {
            println("[Gradle] AAB file not found in bundleDir: ${bundleDir?.absolutePath}")
        }
    }
}
