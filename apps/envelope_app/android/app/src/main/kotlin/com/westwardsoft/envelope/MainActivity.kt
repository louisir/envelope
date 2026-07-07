package com.westwardsoft.envelope

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.BaseColumns
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import android.util.Size
import android.webkit.MimeTypeMap
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.IvParameterSpec
import org.json.JSONObject

class MainActivity : FlutterFragmentActivity() {
    private val channelName = "com.westwardsoft.envelope/secure_store"
    private val adbBridgeChannelName = "com.westwardsoft.envelope/adb_bridge"
    private val adbBridgeAction = "com.westwardsoft.envelope.ADB"
    private val prefsName = "envelope_secure_store"
    private val identityKey = "identity_v1"
    private val chatStoreKey = "chat_store_v1"
    private val localLockEnabledKey = "local_lock_enabled_v1"
    private val syncServiceUrlKey = "sync_service_url_v1"
    private val primaryKeyAlias = "envelope_android_store_master_key_v1"
    private val fallbackKeyAlias = "envelope_android_store_master_key_aes128_v1"
    private val cbcFallbackKeyAlias = "envelope_android_store_master_key_cbc128_v1"
    private val offlineEnvelopePickRequestCode = 6118
    private val fileForSealingPickRequestCode = 6119
    private var adbBridgeChannel: MethodChannel? = null
    private var pendingOfflineEnvelopePickResult: MethodChannel.Result? = null
    private var pendingFileForSealingPickResult: MethodChannel.Result? = null
    private var pendingLocalAuthResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "hasIdentity" -> result.success(hasIdentity())
                        "readIdentity" -> result.success(readIdentityRecord())
                        "writeIdentity" -> {
                            val identityJson = call.argument<String>("identityJson")
                                ?: error("identityJson is required")
                            writeIdentity(identityJson)
                            result.success(identityRecord(identityJson))
                        }
                        "clearIdentity" -> {
                            clearIdentity()
                            result.success(null)
                        }
                        "readChatStore" -> result.success(readEncryptedString(chatStoreKey))
                        "writeChatStore" -> {
                            val storeJson = call.argument<String>("storeJson")
                                ?: error("storeJson is required")
                            writeEncryptedString(chatStoreKey, storeJson)
                            result.success(null)
                        }
                        "clearChatStore" -> {
                            clearEncryptedString(chatStoreKey)
                            result.success(null)
                        }
                        "readSyncServiceUrl" -> {
                            result.success(readEncryptedString(syncServiceUrlKey))
                        }
                        "writeSyncServiceUrl" -> {
                            val serverUrl = call.argument<String>("serverUrl")
                                ?: error("serverUrl is required")
                            writeEncryptedString(syncServiceUrlKey, serverUrl)
                            result.success(null)
                        }
                        "readLocalLockEnabled" -> {
                            result.success(readEncryptedString(localLockEnabledKey) == "1")
                        }
                        "writeLocalLockEnabled" -> {
                            val enabled = call.argument<Boolean>("enabled") ?: false
                            writeEncryptedString(localLockEnabledKey, if (enabled) "1" else "0")
                            result.success(null)
                        }
                        "isLocalAuthenticationAvailable" -> {
                            result.success(isLocalAuthenticationAvailable())
                        }
                        "authenticateLocalUser" -> authenticateLocalUser(call.arguments, result)
                        "getAppSigningCertificateSha256" -> {
                            result.success(appSigningCertificateSha256())
                        }
                        "getDatabasePassword" -> {
                            val dbPasswordKey = "db_password_v1"
                            var password = readEncryptedString(dbPasswordKey)
                            if (password == null) {
                                val randomBytes = ByteArray(32)
                                java.security.SecureRandom().nextBytes(randomBytes)
                                password = Base64.encodeToString(randomBytes, Base64.NO_WRAP)
                                writeEncryptedString(dbPasswordKey, password)
                            }
                            result.success(password)
                        }
                        "getDiagnosticLogDirectory" -> {
                            val dir = File(filesDir, "diagnostic_logs")
                            if (!dir.exists() && !dir.mkdirs()) {
                                error("无法创建诊断日志目录：${dir.absolutePath}")
                            }
                            result.success(dir.absolutePath)
                        }
                        "openContainingFolder" -> openContainingFolder(call.arguments, result)
                        "openSavedFileLocation" -> openSavedFileLocation(call.arguments, result)
                        "pickOfflineEnvelopeFile" -> pickOfflineEnvelopeFile(result)
                        "pickFileForSealing" -> pickFileForSealing(result)
                        "readPickedFileChunk" -> readPickedFileChunk(call.arguments, result)
                        "saveReceivedFile" -> saveReceivedFile(call.arguments, result)
                        "saveSealedEnvelopeFile" -> saveSealedEnvelopeFile(call.arguments, result)
                        "createSavedFile" -> createSavedFile(call.arguments, result)
                        "appendSavedFileBytes" -> appendSavedFileBytes(call.arguments, result)
                        "finishSavedFile" -> finishSavedFile(call.arguments, result)
                        "openSavedFile" -> openSavedFile(call.arguments, result)
                        "loadSavedFilePreview" -> loadSavedFilePreview(call.arguments, result)
                        "clearEnvelopeCache" -> clearEnvelopeCache(result)
                        "deleteSavedFile" -> deleteSavedFile(call.arguments, result)
                        else -> result.notImplemented()
                    }
                } catch (error: Throwable) {
                    result.error("ENVELOPE_SECURE_STORE", error.toString(), null)
                }
            }

        adbBridgeChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            adbBridgeChannelName,
        )
        val initialIntent = intent
        Handler(Looper.getMainLooper()).postDelayed({
            handleAdbIntent(initialIntent)
        }, 1000)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleAdbIntent(intent)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == offlineEnvelopePickRequestCode) {
            handleOfflineEnvelopePickResult(resultCode, data)
            return
        }
        if (requestCode == fileForSealingPickRequestCode) {
            handleFileForSealingPickResult(resultCode, data)
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        pendingOfflineEnvelopePickResult?.success(null)
        pendingOfflineEnvelopePickResult = null
        pendingFileForSealingPickResult?.success(null)
        pendingFileForSealingPickResult = null
        pendingLocalAuthResult?.success(false)
        pendingLocalAuthResult = null
        super.onDestroy()
    }

    private fun handleAdbIntent(intent: Intent?) {
        if (!isDebuggable() && !BuildConfig.ENVELOPE_ADB_BRIDGE) {
            return
        }
        if (intent?.action != adbBridgeAction) {
            return
        }

        val command = intent.getStringExtra("command")
        if (command.isNullOrBlank()) {
            Log.e("EnvelopeAdbBridge", "ENVELOPE_ADB_ERROR missing command")
            return
        }

        val args = hashMapOf<String, Any?>("command" to command)
        val stringExtras = listOf(
            "payload",
            "payload_base64",
            "request_id",
            "recipient_key_id",
            "text",
            "display_name",
            "timeout_millis",
            "path",
            "name",
            "mime",
            "envelope_id",
            "server_url",
            "group_id",
            "policy",
            "member_key_ids",
            "member_key_id",
            "avatar_seed",
        )
        for (key in stringExtras) {
            val value = intent.getStringExtra(key)
            if (value != null) {
                args[key] = value
            }
        }

        val channel = adbBridgeChannel
        if (channel == null) {
            Log.e("EnvelopeAdbBridge", "ENVELOPE_ADB_ERROR bridge channel unavailable")
            return
        }

        channel.invokeMethod(
            "handleCommand",
            args,
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    logAdbBridgeResult(result?.toString() ?: "")
                }

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                    Log.e("EnvelopeAdbBridge", "ENVELOPE_ADB_ERROR $errorCode $errorMessage")
                }

                override fun notImplemented() {
                    Log.e("EnvelopeAdbBridge", "ENVELOPE_ADB_ERROR not implemented")
                }
            },
        )
    }

    private fun logAdbBridgeResult(payload: String) {
        val chunkSize = 2400
        if (payload.length <= chunkSize) {
            Log.i("EnvelopeAdbBridge", "ENVELOPE_ADB_RESULT $payload")
            return
        }
        val id = System.currentTimeMillis().toString(36)
        val total = (payload.length + chunkSize - 1) / chunkSize
        for (index in 0 until total) {
            val start = index * chunkSize
            val end = minOf(start + chunkSize, payload.length)
            Log.i(
                "EnvelopeAdbBridge",
                "ENVELOPE_ADB_RESULT_CHUNK $id ${index + 1}/$total ${payload.substring(start, end)}",
            )
        }
    }

    private fun hasIdentity(): Boolean =
        securePrefs().contains(identityKey)

    private fun readIdentityRecord(): Map<String, Any?>? {
        val identityJson = readEncryptedString(identityKey) ?: return null
        return identityRecord(identityJson)
    }

    private fun writeIdentity(identityJson: String) {
        writeEncryptedString(identityKey, identityJson)
    }

    private fun clearIdentity() {
        clearEncryptedString(identityKey)
    }

    private fun identityRecord(identityJson: String): Map<String, Any?> {
        val root = JSONObject(identityJson)
        val public = root.optJSONObject("public")
        return mapOf(
            "identityJson" to identityJson,
            "keyId" to (public?.optString("key_id") ?: ""),
            "displayName" to root.optString("display_name"),
        )
    }

    private fun readEncryptedString(key: String): String? {
        val payload = securePrefs().getString(key, null) ?: return null
        return decrypt(payload)
    }

    private fun writeEncryptedString(key: String, plainText: String) {
        val record = encrypt(plainText)
        securePrefs()
            .edit()
            .putString(key, record)
            .apply()
    }

    private fun clearEncryptedString(key: String) {
        securePrefs().edit().remove(key).apply()
    }

    private fun encrypt(plainText: String): String {
        return try {
            encryptWithAlias(plainText, primaryKeyAlias, 256, includeAlias = false)
        } catch (error: Throwable) {
            Log.w(
                "EnvelopeSecureStore",
                "Primary AndroidKeyStore AES-256 key failed; falling back to AES-128.",
                error,
            )
            try {
                encryptWithAlias(plainText, fallbackKeyAlias, 128, includeAlias = true)
            } catch (fallbackError: Throwable) {
                Log.w(
                    "EnvelopeSecureStore",
                    "AndroidKeyStore AES-GCM fallback failed; falling back to AES-CBC.",
                    fallbackError,
                )
                encryptWithCbcAlias(plainText)
            }
        }
    }

    private fun encryptWithAlias(
        plainText: String,
        alias: String,
        keySize: Int,
        includeAlias: Boolean,
    ): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.ENCRYPT_MODE,
            getOrCreateStoreKey(
                alias,
                keySize,
                KeyProperties.BLOCK_MODE_GCM,
                KeyProperties.ENCRYPTION_PADDING_NONE,
            ),
        )
        val ciphertext = cipher.doFinal(plainText.toByteArray(Charsets.UTF_8))
        val record = JSONObject()
            .put("version", 1)
            .put("alg", if (keySize == 128) "AES-128-GCM" else "AES-256-GCM")
            .put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .put("ciphertext", Base64.encodeToString(ciphertext, Base64.NO_WRAP))
        if (includeAlias) {
            record.put("key_alias", alias)
        }
        return record.toString()
    }

    private fun encryptWithCbcAlias(plainText: String): String {
        val cipher = Cipher.getInstance("AES/CBC/PKCS7Padding")
        cipher.init(
            Cipher.ENCRYPT_MODE,
            getOrCreateStoreKey(
                cbcFallbackKeyAlias,
                128,
                KeyProperties.BLOCK_MODE_CBC,
                KeyProperties.ENCRYPTION_PADDING_PKCS7,
            ),
        )
        val ciphertext = cipher.doFinal(plainText.toByteArray(Charsets.UTF_8))
        return JSONObject()
            .put("version", 1)
            .put("alg", "AES-128-CBC-PKCS7")
            .put("key_alias", cbcFallbackKeyAlias)
            .put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .put("ciphertext", Base64.encodeToString(ciphertext, Base64.NO_WRAP))
            .toString()
    }

    private fun decrypt(payload: String): String {
        val record = JSONObject(payload)
        val version = record.optInt("version")
        if (version != 1) {
            error("unsupported secure store version: $version")
        }

        val iv = Base64.decode(record.getString("iv"), Base64.NO_WRAP)
        val ciphertext = Base64.decode(record.getString("ciphertext"), Base64.NO_WRAP)
        val alg = record.optString("alg", "AES-256-GCM")
        val alias = record.optString("key_alias", primaryKeyAlias)
        val keySize = if (alias == fallbackKeyAlias || alias == cbcFallbackKeyAlias) 128 else 256
        val cipher = if (alg == "AES-128-CBC-PKCS7") {
            Cipher.getInstance("AES/CBC/PKCS7Padding")
        } else {
            Cipher.getInstance("AES/GCM/NoPadding")
        }
        val key = if (alg == "AES-128-CBC-PKCS7") {
            getOrCreateStoreKey(
                alias,
                keySize,
                KeyProperties.BLOCK_MODE_CBC,
                KeyProperties.ENCRYPTION_PADDING_PKCS7,
            )
        } else {
            getOrCreateStoreKey(
                alias,
                keySize,
                KeyProperties.BLOCK_MODE_GCM,
                KeyProperties.ENCRYPTION_PADDING_NONE,
            )
        }
        if (alg == "AES-128-CBC-PKCS7") {
            cipher.init(Cipher.DECRYPT_MODE, key, IvParameterSpec(iv))
        } else {
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, iv))
        }
        return String(cipher.doFinal(ciphertext), Charsets.UTF_8)
    }

    private fun getOrCreateStoreKey(
        alias: String,
        keySize: Int,
        blockMode: String,
        padding: String,
    ): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore")
        keyStore.load(null)

        val existing = keyStore.getEntry(alias, null) as? KeyStore.SecretKeyEntry
        if (existing != null) {
            return existing.secretKey
        }

        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore",
        )
        val spec = KeyGenParameterSpec.Builder(
            alias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(blockMode)
            .setEncryptionPaddings(padding)
            .setKeySize(keySize)
            .setRandomizedEncryptionRequired(true)
            .build()
        generator.init(spec)
        return generator.generateKey()
    }

    private fun securePrefs() =
        getSharedPreferences(prefsName, Context.MODE_PRIVATE)

    private fun localAuthenticators(): Int =
        BiometricManager.Authenticators.BIOMETRIC_STRONG or
            BiometricManager.Authenticators.DEVICE_CREDENTIAL

    private fun isLocalAuthenticationAvailable(): Boolean {
        val status = BiometricManager.from(this).canAuthenticate(localAuthenticators())
        return status == BiometricManager.BIOMETRIC_SUCCESS
    }

    private fun authenticateLocalUser(arguments: Any?, result: MethodChannel.Result) {
        if (!isLocalAuthenticationAvailable()) {
            result.success(false)
            return
        }
        if (pendingLocalAuthResult != null) {
            result.error("ENVELOPE_AUTH_BUSY", "local authentication is already running", null)
            return
        }

        val args = arguments as? Map<*, *> ?: emptyMap<String, Any?>()
        val title = args["title"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
            ?: "Unlock Envelope"
        val subtitle = args["subtitle"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }

        val promptBuilder = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setAllowedAuthenticators(localAuthenticators())
        if (subtitle != null) {
            promptBuilder.setSubtitle(subtitle)
        }

        val executor = ContextCompat.getMainExecutor(this)
        val prompt = BiometricPrompt(
            this,
            executor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    finishLocalAuthentication(false)
                }

                override fun onAuthenticationSucceeded(
                    resultInfo: BiometricPrompt.AuthenticationResult,
                ) {
                    finishLocalAuthentication(true)
                }

                override fun onAuthenticationFailed() {
                    // The prompt stays open; the final result arrives through success or error.
                }
            },
        )

        pendingLocalAuthResult = result
        prompt.authenticate(promptBuilder.build())
    }

    private fun finishLocalAuthentication(success: Boolean) {
        val result = pendingLocalAuthResult ?: return
        pendingLocalAuthResult = null
        result.success(success)
    }

    @Suppress("DEPRECATION")
    private fun appSigningCertificateSha256(): String {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val packageInfo = packageManager.getPackageInfo(
                packageName,
                PackageManager.GET_SIGNING_CERTIFICATES,
            )
            packageInfo.signingInfo?.apkContentsSigners
        } else {
            val packageInfo = packageManager.getPackageInfo(
                packageName,
                PackageManager.GET_SIGNATURES,
            )
            packageInfo.signatures
        }
        val signature = signatures?.firstOrNull() ?: return ""
        val digest = MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
        return digest.joinToString(":") { byte -> "%02X".format(byte) }
    }

    private fun openContainingFolder(arguments: Any?, result: MethodChannel.Result) {
        val args = arguments as? Map<*, *> ?: error("openContainingFolder arguments are required")
        val path = args["path"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
            ?: error("path is required")
        try {
            val savedFileUri = resolveSavedFileUri(path, path)
            val folder = resolveSavedFileFolder(path, path) ?: run {
                if (path.startsWith("content://")) {
                    null
                } else {
                    val target = File(path)
                    if (target.isDirectory) target else target.parentFile
                }
            } ?: error("无法定位目录：$path")
            result.success(openFolderLocation(folder, savedFileUri))
        } catch (error: Throwable) {
            result.error("ENVELOPE_SECURE_STORE", error.message, null)
        }
    }

    private fun openSavedFileLocation(arguments: Any?, result: MethodChannel.Result) {
        val args = arguments as? Map<*, *> ?: error("openSavedFileLocation arguments are required")
        val rawUri = args["uri"]?.toString()
        val rawPath = args["path"]?.toString()
        val savedFileUri = resolveSavedFileUri(rawUri, rawPath)
            ?: error("无法定位接收文件：${rawPath ?: rawUri ?: ""}")
        val folder = resolveSavedFileFolder(rawUri, rawPath)
            ?: error("无法定位保存目录：${rawPath ?: rawUri ?: ""}")
        try {
            verifySavedFileAccess(savedFileUri)
            result.success(openFolderLocation(folder, savedFileUri))
        } catch (error: Throwable) {
            result.error("ENVELOPE_SECURE_STORE", error.message, null)
        }
    }

    private fun openFolderLocation(folder: File, savedFileUri: Uri? = null): Map<String, Any?> {
        if (tryOpenSamsungMyFilesFolder(folder)) {
            return openFolderResult("openedDirectly", "samsungMyFiles", folder)
        }
        if (tryOpenDocumentFolder(folder, savedFileUri)) {
            return openFolderResult("openedDirectly", "documentsView", folder)
        }
        if (tryOpenFileFolder(folder, savedFileUri)) {
            return openFolderResult("openedDirectly", "resourceFolder", folder)
        }
        if (tryOpenDocumentTreeFolder(folder)) {
            return openFolderResult("openedPickerAtFolder", "documentTree", folder)
        }
        error("没有可打开该文件夹的应用：${folder.absolutePath}")
    }

    private fun openFolderResult(
        status: String,
        method: String,
        folder: File,
    ): Map<String, Any?> = mapOf(
        "status" to status,
        "method" to method,
        "folderPath" to folder.absolutePath,
    )

    private fun tryOpenDocumentFolder(folder: File, savedFileUri: Uri? = null): Boolean {
        val documentUri = externalStorageDocumentUriForFolder(folder) ?: return false
        val viewIntent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(documentUri, DocumentsContract.Document.MIME_TYPE_DIR)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            .also { addSavedFileReadGrant(it, savedFileUri) }
        return tryStartActivity(viewIntent)
    }

    private fun tryOpenDocumentTreeFolder(folder: File): Boolean {
        val documentUri = externalStorageDocumentUriForFolder(folder) ?: return false
        val treeIntent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
            .putExtra(DocumentsContract.EXTRA_INITIAL_URI, documentUri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            .addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            .addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            .addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        return tryStartActivity(treeIntent)
    }

    private fun externalStorageDocumentUriForFolder(folder: File): Uri? {
        val externalRoot = Environment.getExternalStorageDirectory().absoluteFile
        val folderFile = folder.absoluteFile
        val relative = folderFile.relativeToOrNull(externalRoot)?.path
            ?.replace(File.separatorChar, '/')
            ?: return null
        val documentId = if (relative.isBlank()) {
            "primary:"
        } else {
            "primary:$relative"
        }
        return DocumentsContract.buildDocumentUri(
            "com.android.externalstorage.documents",
            documentId,
        )
    }

    private fun tryOpenSamsungMyFilesFolder(folder: File): Boolean {
        if (packageManager.getLaunchIntentForPackage("com.sec.android.app.myfiles") == null) {
            return false
        }
        val intent = Intent("samsung.myfiles.intent.action.LAUNCH_MY_FILES")
            .setPackage("com.sec.android.app.myfiles")
            .putExtra(
                "samsung.myfiles.intent.extra.START_PATH",
                folder.absolutePath,
            )
        return tryStartActivity(intent)
    }

    private fun tryOpenFileFolder(folder: File, savedFileUri: Uri? = null): Boolean {
        val uri = Uri.fromFile(folder)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "resource/folder")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            .also { addSavedFileReadGrant(it, savedFileUri) }
        return tryStartActivity(intent)
    }

    private fun addSavedFileReadGrant(intent: Intent, savedFileUri: Uri?) {
        if (savedFileUri == null || savedFileUri.scheme != "content") {
            return
        }
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        intent.clipData = ClipData.newUri(contentResolver, "Envelope received file", savedFileUri)
    }

    private fun tryStartActivity(intent: Intent): Boolean {
        return try {
            startActivity(intent)
            true
        } catch (error: ActivityNotFoundException) {
            Log.w("EnvelopeSecureStore", "No activity can handle intent: $intent", error)
            false
        } catch (error: SecurityException) {
            Log.w("EnvelopeSecureStore", "Activity launch denied: $intent", error)
            false
        } catch (error: RuntimeException) {
            Log.w("EnvelopeSecureStore", "Activity launch failed: $intent", error)
            false
        }
    }

    private fun pickOfflineEnvelopeFile(result: MethodChannel.Result) {
        if (pendingOfflineEnvelopePickResult != null) {
            error("offline envelope picker is already running")
        }
        pendingOfflineEnvelopePickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf(
                    "application/octet-stream",
                    "application/envelope",
                    "text/plain",
                ),
            )
        }
        try {
            startActivityForResult(intent, offlineEnvelopePickRequestCode)
        } catch (error: Throwable) {
            pendingOfflineEnvelopePickResult = null
            result.error("ENVELOPE_SECURE_STORE", error.message, null)
        }
    }

    private fun pickFileForSealing(result: MethodChannel.Result) {
        if (pendingFileForSealingPickResult != null) {
            error("file picker is already running")
        }
        pendingFileForSealingPickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }
        try {
            startActivityForResult(intent, fileForSealingPickRequestCode)
        } catch (error: Throwable) {
            pendingFileForSealingPickResult = null
            result.error("ENVELOPE_SECURE_STORE", error.message, null)
        }
    }

    private fun handleOfflineEnvelopePickResult(resultCode: Int, data: Intent?) {
        val result = pendingOfflineEnvelopePickResult ?: return
        pendingOfflineEnvelopePickResult = null
        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return
        }
        val uri = data?.data
        if (uri == null) {
            result.error("ENVELOPE_SECURE_STORE", "未选择离线信封文件。", null)
            return
        }
        try {
            persistReadPermission(data, uri)
            result.success(
                mapOf(
                    "name" to displayNameForUri(uri),
                    "mime" to (contentResolver.getType(uri) ?: "application/octet-stream"),
                    "uri" to uri.toString(),
                    "size" to sizeForUri(uri),
                ),
            )
        } catch (error: Throwable) {
            result.error("ENVELOPE_SECURE_STORE", error.message, null)
        }
    }

    private fun handleFileForSealingPickResult(resultCode: Int, data: Intent?) {
        val result = pendingFileForSealingPickResult ?: return
        pendingFileForSealingPickResult = null
        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return
        }
        val uri = data?.data
        if (uri == null) {
            result.error("ENVELOPE_SECURE_STORE", "未选择文件。", null)
            return
        }
        try {
            persistReadPermission(data, uri)
            result.success(
                mapOf(
                    "name" to displayNameForUri(uri),
                    "mime" to (contentResolver.getType(uri) ?: "application/octet-stream"),
                    "uri" to uri.toString(),
                    "size" to sizeForUri(uri),
                ),
            )
        } catch (error: Throwable) {
            result.error("ENVELOPE_SECURE_STORE", error.message, null)
        }
    }

    private fun readPickedFileChunk(arguments: Any?, result: MethodChannel.Result) {
        val args = arguments as? Map<*, *> ?: error("readPickedFileChunk arguments are required")
        val uri = Uri.parse(args["uri"]?.toString() ?: error("uri is required"))
        val offset = (args["offset"] as? Number)?.toLong() ?: error("offset is required")
        val length = (args["length"] as? Number)?.toInt() ?: error("length is required")
        if (offset < 0) {
            error("offset must be non-negative")
        }
        if (length <= 0 || length > 8 * 1024 * 1024) {
            error("length must be between 1 byte and 8 MiB")
        }
        try {
            contentResolver.openInputStream(uri)?.use { stream ->
                var remaining = offset
                while (remaining > 0) {
                    val skipped = stream.skip(remaining)
                    if (skipped > 0) {
                        remaining -= skipped
                        continue
                    }
                    if (stream.read() == -1) {
                        result.success(ByteArray(0))
                        return
                    }
                    remaining -= 1
                }

                val buffer = ByteArray(length)
                var total = 0
                while (total < length) {
                    val read = stream.read(buffer, total, length - total)
                    if (read <= 0) {
                        break
                    }
                    total += read
                }
                result.success(if (total == length) buffer else buffer.copyOf(total))
            } ?: error("无法读取文件。")
        } catch (error: Throwable) {
            result.error("ENVELOPE_SECURE_STORE", error.message, null)
        }
    }

    private fun saveReceivedFile(arguments: Any?, result: MethodChannel.Result) {
        val args = arguments as? Map<*, *> ?: error("saveReceivedFile arguments are required")
        val requestedName = args["name"]?.toString() ?: "file"
        val mime = args["mime"]?.toString()?.takeIf { it.isNotBlank() }
            ?: "application/octet-stream"
        val bytes = args["bytes"] as? ByteArray ?: error("bytes are required")
        saveBytesToDownloadsEnvelope(
            requestedName = requestedName,
            mime = mime,
            bytes = bytes,
            childDir = "received",
            result = result,
        )
    }

    private fun saveSealedEnvelopeFile(arguments: Any?, result: MethodChannel.Result) {
        val args = arguments as? Map<*, *> ?: error("saveSealedEnvelopeFile arguments are required")
        val requestedName = args["name"]?.toString() ?: "sealed.envelope"
        val bytes = args["bytes"] as? ByteArray ?: error("bytes are required")
        saveBytesToDownloadsEnvelope(
            requestedName = requestedName,
            mime = "application/octet-stream",
            bytes = bytes,
            childDir = "sealed",
            result = result,
        )
    }

    private fun saveBytesToDownloadsEnvelope(
        requestedName: String,
        mime: String,
        bytes: ByteArray,
        childDir: String,
        result: MethodChannel.Result,
    ) {
        val fileName = sanitizeFileName(requestedName)
        val normalizedChildDir = sanitizePathSegment(childDir)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val relativePath =
                    "${Environment.DIRECTORY_DOWNLOADS}/Envelope/$normalizedChildDir"
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                    put(MediaStore.MediaColumns.MIME_TYPE, mime)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val uri = contentResolver.insert(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                    values,
                ) ?: error("无法创建接收文件。")
                try {
                    contentResolver.openOutputStream(uri)?.use { stream ->
                        stream.write(bytes)
                    } ?: error("无法写入接收文件。")
                    values.clear()
                    values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                    contentResolver.update(uri, values, null, null)
                    result.success(
                        mapOf(
                            "name" to fileName,
                            "mime" to mime,
                            "uri" to uri.toString(),
                            "displayPath" to "Download/Envelope/$normalizedChildDir/$fileName",
                            "bytes" to bytes.size,
                        ),
                    )
                } catch (error: Throwable) {
                    contentResolver.delete(uri, null, null)
                    throw error
                }
                return
            }

            @Suppress("DEPRECATION")
            val dir = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                "Envelope/$normalizedChildDir",
            )
            if (!dir.exists() && !dir.mkdirs()) {
                error("无法创建接收文件目录：${dir.absolutePath}")
            }
            val file = uniqueFile(File(dir, fileName))
            file.writeBytes(bytes)
            result.success(
                mapOf(
                    "name" to file.name,
                    "mime" to mime,
                    "uri" to Uri.fromFile(file).toString(),
                    "displayPath" to file.absolutePath,
                    "bytes" to bytes.size,
                ),
            )
        } catch (error: Throwable) {
            result.error("ENVELOPE_SECURE_STORE", error.message, null)
        }
    }

    private fun createSavedFile(arguments: Any?, result: MethodChannel.Result) {
        val args = arguments as? Map<*, *> ?: error("createSavedFile arguments are required")
        val requestedName = args["name"]?.toString() ?: "file"
        val mime = args["mime"]?.toString()?.takeIf { it.isNotBlank() }
            ?: "application/octet-stream"
        val childDir = args["childDir"]?.toString() ?: "files"
        val fileName = sanitizeFileName(requestedName)
        val normalizedChildDir = sanitizePathSegment(childDir)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val relativePath =
                    "${Environment.DIRECTORY_DOWNLOADS}/Envelope/$normalizedChildDir"
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                    put(MediaStore.MediaColumns.MIME_TYPE, mime)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val uri = contentResolver.insert(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                    values,
                ) ?: error("无法创建文件。")
                result.success(
                    mapOf(
                        "name" to fileName,
                        "mime" to mime,
                        "uri" to uri.toString(),
                        "displayPath" to "Download/Envelope/$normalizedChildDir/$fileName",
                        "bytes" to 0,
                    ),
                )
                return
            }

            @Suppress("DEPRECATION")
            val dir = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                "Envelope/$normalizedChildDir",
            )
            if (!dir.exists() && !dir.mkdirs()) {
                error("无法创建文件目录：${dir.absolutePath}")
            }
            val file = uniqueFile(File(dir, fileName))
            if (!file.createNewFile()) {
                error("无法创建文件：${file.absolutePath}")
            }
            result.success(
                mapOf(
                    "name" to file.name,
                    "mime" to mime,
                    "uri" to Uri.fromFile(file).toString(),
                    "displayPath" to file.absolutePath,
                    "bytes" to 0,
                ),
            )
        } catch (error: Throwable) {
            result.error("ENVELOPE_SECURE_STORE", error.message, null)
        }
    }

    private fun appendSavedFileBytes(arguments: Any?, result: MethodChannel.Result) {
        val args = arguments as? Map<*, *> ?: error("appendSavedFileBytes arguments are required")
        val uri = Uri.parse(args["uri"]?.toString() ?: error("uri is required"))
        val bytes = args["bytes"] as? ByteArray ?: error("bytes are required")
        try {
            when (uri.scheme) {
                "content" -> {
                    contentResolver.openOutputStream(uri, "wa")?.use { stream ->
                        stream.write(bytes)
                    } ?: error("无法写入文件。")
                }
                "file" -> {
                    val file = File(uri.path ?: error("file uri path is empty"))
                    java.io.FileOutputStream(file, true).use { stream ->
                        stream.write(bytes)
                    }
                }
                else -> error("不支持的文件 URI：$uri")
            }
            result.success(null)
        } catch (error: Throwable) {
            result.error("ENVELOPE_SECURE_STORE", error.message, null)
        }
    }

    private fun finishSavedFile(arguments: Any?, result: MethodChannel.Result) {
        val args = arguments as? Map<*, *> ?: error("finishSavedFile arguments are required")
        val uriText = args["uri"]?.toString() ?: error("uri is required")
        val uri = Uri.parse(uriText)
        val name = args["name"]?.toString() ?: "file"
        val mime = args["mime"]?.toString() ?: "application/octet-stream"
        val displayPath = args["displayPath"]?.toString() ?: ""
        val bytes = (args["bytes"] as? Number)?.toLong() ?: 0L
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && uri.scheme == "content") {
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                }
                contentResolver.update(uri, values, null, null)
            }
            result.success(
                mapOf(
                    "name" to name,
                    "mime" to mime,
                    "uri" to uriText,
                    "displayPath" to displayPath,
                    "bytes" to bytes,
                ),
            )
        } catch (error: Throwable) {
            result.error("ENVELOPE_SECURE_STORE", error.message, null)
        }
    }

    private fun sanitizePathSegment(value: String): String {
        return sanitizeFileName(value).takeIf { it.isNotBlank() } ?: "files"
    }

    private fun openSavedFile(arguments: Any?, result: MethodChannel.Result) {
        val args = arguments as? Map<*, *> ?: error("openSavedFile arguments are required")
        val rawUri = args["uri"]?.toString()
        val rawPath = args["path"]?.toString()
        val uri = resolveSavedFileUri(rawUri, rawPath)
            ?: error("无法定位接收文件：${rawPath ?: rawUri ?: ""}")
        val mime = mimeForOpen(uri, rawPath, args["mime"]?.toString())
        try {
            if (!tryOpenSavedFile(uri, mime) && mime != "*/*") {
                if (!tryOpenSavedFile(uri, "*/*")) {
                    error("没有可打开该文件的应用。")
                }
            }
            result.success(null)
        } catch (error: Throwable) {
            result.error("ENVELOPE_SECURE_STORE", error.message, null)
        }
    }

    private fun loadSavedFilePreview(arguments: Any?, result: MethodChannel.Result) {
        val args = arguments as? Map<*, *> ?: error("loadSavedFilePreview arguments are required")
        val rawUri = args["uri"]?.toString()
        val rawPath = args["path"]?.toString()
        val suppliedMime = args["mime"]?.toString()
        val maxSize = ((args["maxSize"] as? Number)?.toInt() ?: 512).coerceIn(96, 1024)
        val uri = resolveSavedFileUri(rawUri, rawPath)
            ?: error("无法定位预览文件：${rawPath ?: rawUri ?: ""}")
        val mime = mimeForOpen(uri, rawPath, suppliedMime)
        try {
            val bitmap = loadPreviewBitmap(uri, mime, maxSize)
            if (bitmap == null) {
                result.success(null)
                return
            }
            ByteArrayOutputStream().use { output ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 82, output)
                result.success(
                    mapOf(
                        "bytes" to output.toByteArray(),
                        "mime" to "image/jpeg",
                        "width" to bitmap.width,
                        "height" to bitmap.height,
                    ),
                )
            }
        } catch (error: Throwable) {
            result.error("ENVELOPE_SECURE_STORE", error.message, null)
        }
    }

    private fun clearEnvelopeCache(result: MethodChannel.Result) {
        try {
            val receivedDeleted = clearEnvelopeCacheDir("received")
            val sealedDeleted = clearEnvelopeCacheDir("sealed")
            result.success(
                mapOf(
                    "receivedDeleted" to receivedDeleted,
                    "sealedDeleted" to sealedDeleted,
                ),
            )
        } catch (error: Throwable) {
            result.error("ENVELOPE_SECURE_STORE", error.message, null)
        }
    }

    private fun deleteSavedFile(arguments: Any?, result: MethodChannel.Result) {
        val args = arguments as? Map<*, *> ?: error("deleteSavedFile arguments are required")
        val rawUri = args["uri"]?.toString()
        val rawPath = args["path"]?.toString()
        try {
            val deleted = deleteResolvedSavedFile(rawUri, rawPath)
            result.success(deleted)
        } catch (error: Throwable) {
            result.error("ENVELOPE_SECURE_STORE", error.message, null)
        }
    }

    private fun deleteResolvedSavedFile(rawUri: String?, rawPath: String?): Boolean {
        val uri = resolveSavedFileUri(rawUri, rawPath)
        if (uri != null) {
            if (uri.scheme == "content") {
                return contentResolver.delete(uri, null, null) > 0
            }
            if (uri.scheme == "file") {
                val file = File(uri.path ?: return false)
                return !file.exists() || file.delete()
            }
        }

        val path = rawPath?.trim()?.takeIf { it.isNotEmpty() }
            ?: rawUri?.trim()?.takeIf { it.isNotEmpty() }
            ?: return false
        val file = resolveSavedFile(path) ?: return false
        return !file.exists() || file.delete()
    }

    private fun loadPreviewBitmap(uri: Uri, mime: String, maxSize: Int): Bitmap? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && uri.scheme == "content") {
            val thumbnail = try {
                contentResolver.loadThumbnail(uri, Size(maxSize, maxSize), null)
            } catch (error: Throwable) {
                Log.w("EnvelopeSecureStore", "loadThumbnail failed for $uri", error)
                null
            }
            if (thumbnail != null) {
                return thumbnail
            }
        }
        if (!mime.startsWith("image/")) {
            return null
        }
        return decodeScaledBitmap(uri, maxSize)
    }

    private fun decodeScaledBitmap(uri: Uri, maxSize: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply {
            inJustDecodeBounds = true
        }
        contentResolver.openInputStream(uri)?.use { input ->
            BitmapFactory.decodeStream(input, null, bounds)
        }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            return null
        }

        var sampleSize = 1
        while ((bounds.outWidth / sampleSize) > maxSize ||
            (bounds.outHeight / sampleSize) > maxSize
        ) {
            sampleSize *= 2
        }
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
        }
        return contentResolver.openInputStream(uri)?.use { input ->
            BitmapFactory.decodeStream(input, null, options)
        }
    }

    private fun clearEnvelopeCacheDir(childDir: String): Int {
        val deletedFromMediaStore = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            deleteMediaStoreDownloadsUnder("Envelope/$childDir")
        } else {
            0
        }
        @Suppress("DEPRECATION")
        val folder = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            "Envelope/$childDir",
        )
        return deletedFromMediaStore + deleteDirectoryContents(folder)
    }

    private fun deleteMediaStoreDownloadsUnder(relativeDir: String): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return 0
        }
        val normalized = relativeDir.trim('/').replace('\\', '/')
        val downloadsPrefix = "${Environment.DIRECTORY_DOWNLOADS}/$normalized/"
        val legacyDownloadsPrefix = "Downloads/$normalized/"
        val selection = "${MediaStore.MediaColumns.RELATIVE_PATH} = ? OR " +
            "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ? OR " +
            "${MediaStore.MediaColumns.RELATIVE_PATH} = ? OR " +
            "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?"
        val selectionArgs = arrayOf(
            downloadsPrefix,
            "$downloadsPrefix%",
            legacyDownloadsPrefix,
            "$legacyDownloadsPrefix%",
        )
        return contentResolver.delete(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            selection,
            selectionArgs,
        )
    }

    private fun deleteDirectoryContents(folder: File): Int {
        if (!folder.exists()) {
            return 0
        }
        var deleted = 0
        folder.listFiles()?.forEach { child ->
            deleted += deleteRecursivelyCounting(child)
        }
        return deleted
    }

    private fun deleteRecursivelyCounting(file: File): Int {
        if (!file.exists()) {
            return 0
        }
        if (file.isDirectory) {
            var deleted = 0
            file.listFiles()?.forEach { child ->
                deleted += deleteRecursivelyCounting(child)
            }
            if (file.delete()) {
                deleted += 1
            }
            return deleted
        }
        return if (file.delete()) 1 else 0
    }

    private fun resolveSavedFileUri(rawUri: String?, rawPath: String?): Uri? {
        val uriText = rawUri?.trim()?.takeIf { it.isNotEmpty() }
        if (uriText != null && (uriText.startsWith("content://") || uriText.startsWith("file://"))) {
            return Uri.parse(uriText)
        }

        val path = rawPath?.trim()?.takeIf { it.isNotEmpty() } ?: uriText ?: return null
        if (path.startsWith("content://") || path.startsWith("file://")) {
            return Uri.parse(path)
        }

        resolveDownloadDisplayPath(path)?.let { return it }

        val file = resolveSavedFile(path)
        return if (file != null && file.exists()) Uri.fromFile(file) else null
    }

    private fun resolveSavedFileFolder(rawUri: String?, rawPath: String?): File? {
        val path = rawPath?.trim()?.takeIf { it.isNotEmpty() }
        if (path != null &&
            !path.startsWith("content://") &&
            !path.startsWith("file://")
        ) {
            val file = resolveSavedFile(path) ?: return null
            return if (file.isDirectory) file else file.parentFile
        }

        val uriText = rawUri?.trim()?.takeIf { it.isNotEmpty() } ?: path ?: return null
        if (uriText.startsWith("file://")) {
            val file = File(Uri.parse(uriText).path ?: return null)
            return if (file.isDirectory) file else file.parentFile
        }
        if (uriText.startsWith("content://")) {
            val uri = Uri.parse(uriText)
            return resolveExternalStorageDocumentFolder(uri) ?: resolveMediaStoreFolder(uri)
        }
        return null
    }

    private fun resolveExternalStorageDocumentFolder(uri: Uri): File? {
        if (uri.scheme != "content" || uri.authority != "com.android.externalstorage.documents") {
            return null
        }
        val documentId = try {
            DocumentsContract.getDocumentId(uri)
        } catch (_: Throwable) {
            return null
        }
        val separator = documentId.indexOf(':')
        if (separator < 0) {
            return null
        }
        val volume = documentId.substring(0, separator).lowercase()
        if (volume != "primary") {
            return null
        }
        val relativePath = documentId.substring(separator + 1)
            .replace('\\', '/')
            .trim('/')
        val file = if (relativePath.isBlank()) {
            Environment.getExternalStorageDirectory()
        } else {
            File(Environment.getExternalStorageDirectory(), relativePath)
        }
        return if (file.isDirectory) file else file.parentFile
    }

    private fun resolveMediaStoreFolder(uri: Uri): File? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || uri.scheme != "content") {
            return null
        }
        contentResolver.query(
            uri,
            arrayOf(MediaStore.MediaColumns.RELATIVE_PATH),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val column = cursor.getColumnIndex(MediaStore.MediaColumns.RELATIVE_PATH)
                val relativePath = if (column >= 0 && !cursor.isNull(column)) {
                    cursor.getString(column)
                } else {
                    null
                }
                val normalized = relativePath
                    ?.trim()
                    ?.replace('\\', '/')
                    ?.trim('/')
                    ?.takeIf { it.isNotEmpty() }
                    ?: return null
                val relativeToDownloads = when {
                    normalized == Environment.DIRECTORY_DOWNLOADS -> ""
                    normalized.startsWith("${Environment.DIRECTORY_DOWNLOADS}/") ->
                        normalized.removePrefix("${Environment.DIRECTORY_DOWNLOADS}/")
                    normalized.startsWith("Downloads/") ->
                        normalized.removePrefix("Downloads/")
                    else -> normalized
                }
                @Suppress("DEPRECATION")
                return File(
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                    relativeToDownloads,
                )
            }
        }
        return null
    }

    private fun verifySavedFileAccess(uri: Uri) {
        when (uri.scheme) {
            "content" -> {
                contentResolver.openInputStream(uri)?.use { return }
                error("无法读取接收文件，请重新保存该文件。")
            }
            "file" -> {
                val file = File(uri.path ?: error("文件路径为空。"))
                if (!file.exists()) {
                    error("接收文件不存在：${file.absolutePath}")
                }
                if (!file.canRead()) {
                    error("没有读取该接收文件的权限：${file.absolutePath}")
                }
            }
            else -> error("不支持的接收文件 URI：$uri")
        }
    }

    private fun resolveDownloadDisplayPath(path: String): Uri? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return null
        }

        val normalized = normalizedDisplayPath(path)
        val downloadRoot = "${Environment.DIRECTORY_DOWNLOADS}/"
        val downloadsRoot = "Downloads/"
        val relativePath = when {
            normalized.startsWith(downloadRoot) -> normalized.substringBeforeLast("/")
            normalized.startsWith(downloadsRoot) ->
                "${Environment.DIRECTORY_DOWNLOADS}/${normalized.removePrefix(downloadsRoot)}"
                    .substringBeforeLast("/")
            else -> return null
        }
        val displayName = normalized.substringAfterLast("/").takeIf { it.isNotBlank() }
            ?: return null
        val relativePathWithSlash = if (relativePath.endsWith("/")) {
            relativePath
        } else {
            "$relativePath/"
        }
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val selection = "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND " +
            "(${MediaStore.MediaColumns.RELATIVE_PATH} = ? OR " +
            "${MediaStore.MediaColumns.RELATIVE_PATH} = ?)"
        val selectionArgs = arrayOf(displayName, relativePath, relativePathWithSlash)
        val sortOrder = "${MediaStore.MediaColumns.DATE_MODIFIED} DESC"
        contentResolver.query(
            collection,
            arrayOf(BaseColumns._ID),
            selection,
            selectionArgs,
            sortOrder,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val id = cursor.getLong(cursor.getColumnIndexOrThrow(BaseColumns._ID))
                return ContentUris.withAppendedId(collection, id)
            }
        }
        return null
    }

    private fun normalizedDisplayPath(path: String): String =
        path.trim().replace('\\', '/').trimStart('/')

    private fun resolveSavedFile(path: String): File? {
        val direct = File(path)
        if (direct.isAbsolute) {
            return direct
        }
        val normalized = normalizedDisplayPath(path)
        val relative = when {
            normalized.startsWith("${Environment.DIRECTORY_DOWNLOADS}/") ->
                normalized.removePrefix("${Environment.DIRECTORY_DOWNLOADS}/")
            normalized.startsWith("Downloads/") -> normalized.removePrefix("Downloads/")
            else -> normalized
        }
        @Suppress("DEPRECATION")
        return File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            relative,
        )
    }

    private fun mimeForOpen(uri: Uri, rawPath: String?, suppliedMime: String?): String {
        val normalizedSupplied = suppliedMime
            ?.trim()
            ?.takeIf { it.isNotEmpty() && it != "application/octet-stream" }
        if (normalizedSupplied != null) {
            return normalizedSupplied
        }

        if (uri.scheme == "content") {
            contentResolver.getType(uri)
                ?.takeIf { it.isNotBlank() && it != "application/octet-stream" }
                ?.let { return it }
        }

        val candidatePath = rawPath?.takeIf { it.isNotBlank() } ?: uri.lastPathSegment
        val extension = candidatePath
            ?.substringAfterLast('.', "")
            ?.lowercase()
            ?.takeIf { it.isNotEmpty() }
        val inferred = extension?.let {
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(it)
        }
        return inferred
            ?: suppliedMime?.trim()?.takeIf { it.isNotEmpty() }
            ?: "*/*"
    }

    private fun tryOpenSavedFile(uri: Uri, mime: String): Boolean {
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, mime)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return try {
            startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }

    private fun sanitizeFileName(value: String): String {
        val blocked = "\\/:*?\"<>|"
        val sanitized = value
            .map { char -> if (char.code < 32 || blocked.contains(char)) '_' else char }
            .joinToString("")
            .trim()
            .takeIf { it.isNotEmpty() && it != "." && it != ".." }
            ?: "file"
        return sanitized.take(140)
    }

    private fun uniqueFile(initial: File): File {
        if (!initial.exists()) {
            return initial
        }
        val name = initial.nameWithoutExtension
        val extension = initial.extension.takeIf { it.isNotEmpty() }?.let { ".$it" } ?: ""
        var index = 1
        while (true) {
            val candidate = File(initial.parentFile, "$name-$index$extension")
            if (!candidate.exists()) {
                return candidate
            }
            index += 1
        }
    }

    private fun displayNameForUri(uri: Uri): String {
        contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (column >= 0) {
                    val name = cursor.getString(column)
                    if (!name.isNullOrBlank()) {
                        return name
                    }
                }
            }
        }
        return uri.lastPathSegment?.takeIf { it.isNotBlank() } ?: "file"
    }

    private fun sizeForUri(uri: Uri): Long {
        contentResolver.query(
            uri,
            arrayOf(OpenableColumns.SIZE),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val column = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (column >= 0 && !cursor.isNull(column)) {
                    return cursor.getLong(column)
                }
            }
        }
        return -1L
    }

    private fun persistReadPermission(data: Intent?, uri: Uri) {
        val flags = data?.flags ?: return
        val readFlags = flags and Intent.FLAG_GRANT_READ_URI_PERMISSION
        if (readFlags == 0) {
            return
        }
        try {
            contentResolver.takePersistableUriPermission(uri, readFlags)
        } catch (_: Throwable) {
            // Some providers grant temporary read access only. The immediate send path can still use it.
        }
    }

    private fun isDebuggable(): Boolean =
        (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
}
