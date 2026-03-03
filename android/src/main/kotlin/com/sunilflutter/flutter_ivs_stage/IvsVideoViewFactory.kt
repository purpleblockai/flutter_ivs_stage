package com.sunilflutter.flutter_ivs_stage

import android.content.Context
import android.util.Log
import android.view.View
import android.widget.FrameLayout
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class IvsVideoViewFactory(private val managerProvider: () -> StageManager?) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val params = args as? Map<String, Any?>
        return IvsVideoView(context, viewId, params, managerProvider)
    }
}

class IvsVideoView(
    context: Context,
    private val viewId: Int,
    args: Map<String, Any?>?,
    private val managerProvider: () -> StageManager?
) : PlatformView {
    companion object {
        private const val TAG = "IvsVideoView"
    }

    private val containerView: FrameLayout = FrameLayout(context).apply {
        layoutParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        )
        setBackgroundColor(android.graphics.Color.BLACK)
    }

    private val participantId: String? = args?.get("participantId") as? String
    private val isLocal: Boolean = args?.get("isLocal") as? Boolean ?: false

    init {
        registerWithStageManager()
    }

    override fun getView(): View = containerView

    override fun dispose() {
        val manager = managerProvider() ?: return
        Log.i(TAG, "dispose(viewId=$viewId, isLocal=$isLocal, participantId=$participantId)")
        if (isLocal) {
            manager.removeLocalVideoView(containerView)
        } else {
            val id = participantId
            if (id.isNullOrBlank()) {
                Log.w(TAG, "dispose(viewId=$viewId) missing remote participantId")
            } else {
                manager.removeVideoView(id, containerView)
            }
        }
    }

    private fun registerWithStageManager() {
        val manager = managerProvider() ?: return
        Log.i(TAG, "register(viewId=$viewId, isLocal=$isLocal, participantId=$participantId)")
        if (isLocal) {
            manager.setLocalVideoView(containerView)
        } else {
            val id = participantId
            if (id.isNullOrBlank()) {
                Log.w(TAG, "register(viewId=$viewId) missing remote participantId")
            } else {
                manager.setVideoView(containerView, id)
            }
        }
    }
}
