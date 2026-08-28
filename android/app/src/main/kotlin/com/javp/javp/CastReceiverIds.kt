package com.javp.javp

import android.content.Context

/**
 * Google Cast Styled Media Receiver application IDs from the Cast Developer
 * Console. Stable (`com.javp.javp`) vs Dev (`com.javp.javp.dev`) each have
 * their own receiver so unpublished testing and listings stay separate.
 */
object CastReceiverIds {
    /** Stable / Play / sideload — console app "JAVP". */
    const val STABLE = "40F841A8"

    /** Sideload Dev (`applicationIdSuffix = .dev`) — console app "JAVP Dev". */
    const val DEV = "4A3110E4"

    fun forPackage(packageName: String): String =
        if (packageName.endsWith(".dev")) DEV else STABLE

    fun forContext(context: Context): String = forPackage(context.packageName)
}
