package cleanup

import (
	"log"
	"os"
	"path/filepath"
	"time"

	"github.com/copy-everywhere/server/db"
)

// Start launches a background goroutine that cleans up expired and consumed clips every interval.
func Start(database *db.DB, storagePath string, interval time.Duration) {
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()

		// Run once immediately at startup
		run(database, storagePath)

		for range ticker.C {
			run(database, storagePath)
		}
	}()
}

func run(database *db.DB, storagePath string) {
	deleted := 0

	// Clean up expired clips (TTL-based)
	expired, err := database.GetExpiredClips()
	if err != nil {
		log.Printf("CLEANUP: error fetching expired clips: %v", err)
	} else {
		deleted += deleteClips(database, storagePath, expired)
	}

	// Clean up consumed clips older than 60 seconds (safety net for inline-delete edge cases)
	consumed, err := database.GetConsumedClips(60 * time.Second)
	if err != nil {
		log.Printf("CLEANUP: error fetching consumed clips: %v", err)
	} else {
		deleted += deleteClips(database, storagePath, consumed)
	}

	if deleted > 0 {
		log.Printf("CLEANUP: deleted %d clips", deleted)
	}
}

func deleteClips(database *db.DB, storagePath string, clips []*db.Clip) int {
	deleted := 0
	for _, clip := range clips {
		// Delete file/directory from disk
		if clip.StoragePath != "" {
			dir := filepath.Dir(clip.StoragePath)
			if err := os.RemoveAll(dir); err != nil {
				log.Printf("CLEANUP: error removing files for clip %s: %v", clip.ID, err)
			}
		}

		// For uploading clips, also clean up the uploads directory
		if clip.Status == "uploading" {
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
