package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * `apps.icon`'s optional `px` (docs/PROTOCOL.md): the Mac asks for the layer
 * size it will draw, and the phone keeps its historical sizes when it does not.
 */
class IconSizesTest {

    @Test
    fun withoutPxTheHistoricalSizesStay() {
        assertEquals(216, IconSizes.layer(null))
        assertEquals(96, IconSizes.flat(null))
    }

    @Test
    fun theFlatIconCoversTheVisibleTwoThirdsOfTheLayer() {
        assertEquals(144, IconSizes.flat(216))
        assertEquals(288, IconSizes.flat(432))
        assertEquals(864, IconSizes.flat(1296))
    }

    @Test
    fun requestsAreClampedToWhatTheLauncherDraws() {
        assertEquals(216, IconSizes.layer(50))
        assertEquals(216, IconSizes.layer(0))
        assertEquals(216, IconSizes.layer(-40))
        assertEquals(1296, IconSizes.layer(4096))
        assertEquals(432, IconSizes.layer(432))
        assertEquals(1296, IconSizes.layer(1296))
    }

    @Test
    fun theFlatSizeFollowsTheClampedLayerSize() {
        assertEquals(144, IconSizes.flat(50))
        assertEquals(864, IconSizes.flat(4096))
    }
}
