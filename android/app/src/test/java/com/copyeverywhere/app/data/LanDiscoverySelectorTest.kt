package com.copyeverywhere.app.data

import org.junit.Assert.assertEquals
import org.junit.Test

class LanDiscoverySelectorTest {
    @Test
    fun autoSelectsUniqueServerWhenNoSavedStateExists() {
        val server = makeServer("srv-1", "192.168.1.20", 8080)

        val decision = LanDiscoverySelector.decide(
            servers = listOf(server),
            selectedServer = null,
            source = LanEndpointSource.ManualFallback,
            currentHostUrl = ""
        )

        assertEquals(LanDiscoveryDecision.AutoSelect(server), decision)
    }

    @Test
    fun restoresPersistedSelectionByServerIdAfterHostChange() {
        val selection = StoredLanServerSelection(
            serverId = "srv-1",
            name = "Office Mac",
            host = "192.168.1.20",
            port = 8080,
            source = LanEndpointSource.RestoredSelection
        )
        val server = makeServer("srv-1", "192.168.1.44", 8080)

        val decision = LanDiscoverySelector.decide(
            servers = listOf(server),
            selectedServer = selection,
            source = LanEndpointSource.RestoredSelection,
            currentHostUrl = "http://192.168.1.20:8080"
        )

        assertEquals(LanDiscoveryDecision.Restore(server), decision)
    }

    @Test
    fun defersToConfigWhenMultipleServersExist() {
        val decision = LanDiscoverySelector.decide(
            servers = listOf(
                makeServer("srv-1", "192.168.1.20", 8080),
                makeServer("srv-2", "192.168.1.21", 8080)
            ),
            selectedServer = null,
            source = LanEndpointSource.ManualFallback,
            currentHostUrl = ""
        )

        assertEquals(LanDiscoveryDecision.WaitForSelection, decision)
    }

    @Test
    fun preservesManualFallbackWhenSavedSelectionIsMissing() {
        val selection = StoredLanServerSelection(
            serverId = "srv-1",
            name = "Office Mac",
            host = "192.168.1.20",
            port = 8080,
            source = LanEndpointSource.RestoredSelection
        )

        val decision = LanDiscoverySelector.decide(
            servers = emptyList(),
            selectedServer = selection,
            source = LanEndpointSource.RestoredSelection,
            currentHostUrl = "http://192.168.1.20:8080"
        )

        assertEquals(LanDiscoveryDecision.PreserveManualFallback, decision)
    }

    private fun makeServer(serverId: String, host: String, port: Int) = DiscoveredServer(
        serverId = serverId,
        name = "Server $serverId",
        host = host,
        port = port,
        authRequired = false,
        version = "0.1.0"
    )
}
