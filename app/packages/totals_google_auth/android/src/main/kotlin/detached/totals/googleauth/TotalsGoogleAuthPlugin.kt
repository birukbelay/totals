package detached.totals.googleauth

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.os.Handler
import android.os.Looper
import com.google.android.gms.auth.GoogleAuthUtil
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.Scope
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.Executors

/**
 * Grants OAuth scopes through the Identity AuthorizationClient. Without an
 * activity (a WorkManager engine) only already-granted scopes can be used.
 */
class TotalsGoogleAuthPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.ActivityResultListener {

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingResult: MethodChannel.Result? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "authorize" -> authorize(call, result)
            "clearToken" -> clearToken(call, result)
            else -> result.notImplemented()
        }
    }

    private fun authorize(call: MethodCall, result: MethodChannel.Result) {
        val scopes = call.argument<List<String>>("scopes").orEmpty()
        val interactive = call.argument<Boolean>("interactive") ?: true
        if (scopes.isEmpty()) {
            result.error("invalid_scopes", "No Google scopes were requested.", null)
            return
        }
        if (pendingResult != null) {
            result.error("busy", "Google sign-in is already open.", null)
            return
        }

        val activity = activityBinding?.activity
        val client = if (activity != null) {
            Identity.getAuthorizationClient(activity)
        } else {
            Identity.getAuthorizationClient(context)
        }
        val request = AuthorizationRequest.builder()
            .setRequestedScopes(scopes.map { Scope(it) })
            .build()

        client.authorize(request)
            .addOnSuccessListener { authorization ->
                if (!authorization.hasResolution()) {
                    result.success(toMap(authorization))
                    return@addOnSuccessListener
                }
                val pendingIntent = authorization.pendingIntent
                if (!interactive || activity == null || pendingIntent == null) {
                    result.success(null)
                    return@addOnSuccessListener
                }
                pendingResult = result
                try {
                    activity.startIntentSenderForResult(
                        pendingIntent.intentSender,
                        REQUEST_AUTHORIZE,
                        null,
                        0,
                        0,
                        0,
                        null,
                    )
                } catch (error: IntentSender.SendIntentException) {
                    pendingResult = null
                    result.error("launch_failed", error.message, null)
                }
            }
            .addOnFailureListener { error ->
                result.error(errorCode(error), error.message, null)
            }
    }

    private fun clearToken(call: MethodCall, result: MethodChannel.Result) {
        val token = call.argument<String>("token")
        if (token.isNullOrEmpty()) {
            result.success(null)
            return
        }
        executor.execute {
            try {
                GoogleAuthUtil.clearToken(context, token)
                mainHandler.post { result.success(null) }
            } catch (error: Exception) {
                mainHandler.post {
                    result.error("clear_token_failed", error.message, null)
                }
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_AUTHORIZE) return false
        val result = pendingResult ?: return true
        pendingResult = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(null)
            return true
        }
        try {
            val authorization = Identity.getAuthorizationClient(context)
                .getAuthorizationResultFromIntent(data)
            result.success(toMap(authorization))
        } catch (error: ApiException) {
            result.error(errorCode(error), error.message, null)
        }
        return true
    }

    private fun toMap(authorization: AuthorizationResult): Map<String, Any?> {
        return mapOf(
            "accessToken" to authorization.accessToken,
            "grantedScopes" to authorization.grantedScopes,
            "email" to authorization.toGoogleSignInAccount()?.email,
        )
    }

    private fun errorCode(error: Exception): String {
        return if (error is ApiException) {
            "api_${error.statusCode}"
        } else {
            "authorization_failed"
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
    }

    companion object {
        private const val CHANNEL = "detached.totals/google_auth"
        private const val REQUEST_AUTHORIZE = 0x7a01
    }
}
