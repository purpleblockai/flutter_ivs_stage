package com.sunilflutter.flutter_ivs_stage

import android.graphics.RectF

class StageLayoutCalculator {

    private val layouts: List<List<Int>> = listOf(
        listOf(1),          // 1 participant
        listOf(1, 1),       // 2 participants
        listOf(1, 2),       // 3 participants
        listOf(2, 2),       // 4 participants
        listOf(1, 2, 2),    // 5 participants
        listOf(2, 2, 2),    // 6 participants
        listOf(2, 2, 3),    // 7 participants
        listOf(2, 3, 3),    // 8 participants
        listOf(3, 3, 3),    // 9 participants
        listOf(2, 3, 2, 3), // 10 participants
        listOf(2, 3, 3, 3), // 11 participants
        listOf(3, 3, 3, 3), // 12 participants
    )

    fun calculateFrames(
        participantCount: Int,
        width: Float,
        height: Float,
        padding: Float
    ): List<RectF> {
        if (participantCount > 12) {
            throw IllegalArgumentException("Only 12 participants are supported at this time")
        }
        if (participantCount == 0) {
            return emptyList()
        }

        val isVertical = height > width
        val halfPadding = padding / 2f

        val layout = layouts[participantCount - 1]
        val rowHeight = (if (isVertical) height else width) / layout.size

        val frames = mutableListOf<RectF>()
        var lastMaxX = 0f
        var lastMaxY = 0f

        for (row in layout.indices) {
            val itemWidth = (if (isVertical) width else height) / layout[row]
            val segmentX = (if (isVertical) 0f else lastMaxX) + halfPadding
            val segmentY = (if (isVertical) lastMaxY else 0f) + halfPadding
            val segmentW = (if (isVertical) itemWidth else rowHeight) - padding
            val segmentH = (if (isVertical) rowHeight else itemWidth) - padding

            for (column in 0 until layout[row]) {
                val frameX = if (isVertical) {
                    (itemWidth * column) + halfPadding
                } else {
                    segmentX
                }
                val frameY = if (isVertical) {
                    segmentY
                } else {
                    (itemWidth * column) + halfPadding
                }
                frames.add(RectF(frameX, frameY, frameX + segmentW, frameY + segmentH))
            }

            lastMaxX = segmentX + halfPadding + segmentW
            lastMaxY = segmentY + halfPadding + segmentH
        }

        return frames
    }
}
