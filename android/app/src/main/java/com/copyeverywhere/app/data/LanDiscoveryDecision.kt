package com.copyeverywhere.app.data

sealed interface LanDiscoveryDecision {
    data object None : LanDiscoveryDecision
    data object WaitForSelection : LanDiscoveryDecision
    data object PreserveManualFallback : LanDiscoveryDecision
    data class AutoSelect(val server: DiscoveredServer) : LanDiscoveryDecision
    data class Restore(val server: DiscoveredServer) : LanDiscoveryDecision
}

object LanDiscoverySelector {
    fun decide(
        servers: List<DiscoveredServer>,
        selectedServer: StoredLanServerSelection?,
        source: LanEndpointSource,
        currentHostUrl: String
    ): LanDiscoveryDecision {
        if (selectedServer != null) {
            val restored = servers.firstOrNull { discovered ->
                !discovered.serverId.isNullOrBlank() && discovered.serverId == selectedServer.serverId
            }
            if (restored != null) {
                return LanDiscoveryDecision.Restore(restored)
            }

            return if (source == LanEndpointSource.ManualFallback) {
                LanDiscoveryDecision.None
            } else {
                LanDiscoveryDecision.PreserveManualFallback
            }
        }

        if (currentHostUrl.trim().trimEnd('/').isNotBlank()) {
            return LanDiscoveryDecision.None
        }

        return when {
            servers.size == 1 -> LanDiscoveryDecision.AutoSelect(servers.first())
            servers.size > 1 -> LanDiscoveryDecision.WaitForSelection
            else -> LanDiscoveryDecision.None
        }
    }
}
