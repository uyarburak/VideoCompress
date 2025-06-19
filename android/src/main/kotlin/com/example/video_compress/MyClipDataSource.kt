package com.example.video_compress

import androidx.annotation.NonNull
import com.otaliastudios.transcoder.source.DataSource
import com.otaliastudios.transcoder.source.DataSourceWrapper
import com.otaliastudios.transcoder.source.TrimDataSource

/**
 * A [DataSource] that clips the inner source within the given interval.
 */
@Suppress("unused")
class MyClipDataSource : DataSourceWrapper {

    /**
     * Clip from [clipStartUs] to end of source.
     */
    constructor(
        @NonNull source: DataSource,
        clipStartUs: Long
    ) : super(
        TrimDataSource(source, clipStartUs)
    )

    /**
     * Clip from [clipStartUs] until [clipEndUs] before the end of source.
     */
    constructor(
        @NonNull source: DataSource,
        clipStartUs: Long,
        clipEndUs: Long
    ) : super(
        TrimDataSource(
            source,
            clipStartUs,
            getNonNegativeEndUs(source, clipEndUs)
        )
    )

    companion object {
        private fun getSourceDurationUs(source: DataSource): Long {
            if (!source.isInitialized) source.initialize()
            return source.durationUs
        }

        private fun getNonNegativeEndUs(source: DataSource, endUs: Long): Long {
            val durationUs = getSourceDurationUs(source)
            return (durationUs - endUs).coerceAtLeast(0)
        }
    }
}
