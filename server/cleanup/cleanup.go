package cleanup

import (
	"log"
	"os"
	"path/filepath"
	"time"

	"github.com/copy-everywhere/server/db"
)

// Start launches a background goroutine that falls back stale targeted clips and
// cleans up expired and consumed clips every interval.
func Start(database *db.DB, storagePath string, interval time.Duration, targetedFallbackAfter time.Duration) {
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()

		// Run once immediately at startup
		run(database, storagePath, targetedFallbackAfter)

		for range ticker.C {
			run(database, storagePath, targetedFallbackAfter)
		}
	}()
}

func run(database *db.DB, storagePath string, targetedFallbackAfter time.Duration) {
	deleted := 0

	if targetedFallbackAfter > 0 {
		staleTargeted, fetchErr := database.GetStaleTargetedClips(targetedFallbackAfter)
		if fetchErr != nil {
			log.Printf("CLEANUP: error listing stale targeted clips: %v", fetchErr)
		}
		fallbacks, err := database.FallbackTargetedClips(targetedFallbackAfter)
		if err != nil {
			log.Printf("CLEANUP: error falling back targeted clips: %v", err)
		} else if fallbacks > 0 {
			log.Printf("CLEANUP: moved %d targeted clips to fallback", fallbacks)
			for _, clip := range staleTargeted {
				log.Printf("TARGETED: fallback triggered for clip %s target=%s", clip.ID, deref(clip.TargetDeviceID))
			}
		}
	}

	// Clean up expired clips (TTL-based)
	expired, err := database.GetExpiredClips()
	if err != nil {
		log.Printf("CLEANUP: error fetching expired clips: %v", err)
	} else {
		deleted += deleteClips(database, storagePath, expired, "expired")
	}

	// Clean up consumed clips older than 60 seconds (safety net for inline-delete edge cases)
	consumed, err := database.GetConsumedClips(60 * time.Second)
	if err != nil {
		log.Printf("CLEANUP: error fetching consumed clips: %v", err)
	} else {
		deleted += deleteClips(database, storagePath, consumed, "consumed")
	}

	if deleted > 0 {
		log.Printf("CLEANUP: deleted %d clips", deleted)
	}
}

func deleteClips(database *db.DB, storagePath string, clips []*db.Clip, reason string) int {
	deleted := 0
	for _, clip := range clips {
		if reason == "expired" {
			log.Printf("TARGETED: expiring clip %s status=%s target=%s", clip.ID, clip.Status, deref(clip.TargetDeviceID))
		}

		// Delete file/directory from disk
		if clip.StoragePath != "" {
			dir := filepath.Dir(clip.StoragePath)
			if err := os.RemoveAll(dir); err != nil {
				log.Printf("CLEANUP: error removing files for clip %s: %v", clip.ID, err)
			}
		}

		// For uploading clips, also clean up the uploads directory
		if clip.Status == db.ClipStatusUploading {
			uploadDir := filepath.Join(storagePath, "uploads", clip.ID)
			if err := os.RemoveAll(uploadDir); err != nil {
				log.Printf("CLEANUP: error removing upload dir for clip %s: %v", clip.ID, err)
			}
		}

		// Delete DB record
		if err := database.DeleteClip(clip.ID); err != nil {
			log.Printf("CLEANUP: error deleting clip %s from db: %v", clip.ID, err)
			continue
		}
		deleted++
	}
	return deleted
}

func deref(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}
