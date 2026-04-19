package db

import (
	"crypto/rand"
	"database/sql"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

const idChars = "abcdefghijklmnopqrstuvwxyz0123456789"
const idLength = 6
const deviceIDLength = 8

const (
	ClipStatusReady             = "ready"
	ClipStatusUploading         = "uploading"
	ClipStatusTargetedPending   = "targeted_pending"
	ClipStatusTargetedDelivered = "targeted_delivered"
	ClipStatusTargetedFallback  = "targeted_fallback"
	ClipStatusFailed            = "failed"
)

type Clip struct {
	ID                string     `json:"id"`
	Type              string     `json:"type"`
	Filename          *string    `json:"filename"`
	SizeBytes         int64      `json:"size_bytes"`
	Status            string     `json:"status"`
	CreatedAt         time.Time  `json:"created_at"`
	ExpiresAt         time.Time  `json:"expires_at"`
	StoragePath       string     `json:"storage_path"`
	TargetDeviceID    *string    `json:"target_device_id"`
	SenderDeviceID    *string    `json:"sender_device_id"`
	TargetedPendingAt *time.Time `json:"targeted_pending_at"`
	ConsumedAt        *time.Time `json:"consumed_at"`
}

type Device struct {
	ID         string    `json:"device_id"`
	Name       string    `json:"name"`
	Platform   string    `json:"platform"`
	LastSeenAt time.Time `json:"last_seen_at"`
	CreatedAt  time.Time `json:"created_at"`
}

type DB struct {
	conn *sql.DB
}

func Open(storagePath string) (*DB, error) {
	if err := os.MkdirAll(storagePath, 0755); err != nil {
		return nil, fmt.Errorf("create storage dir: %w", err)
	}

	dbPath := filepath.Join(storagePath, "copy_everywhere.db")
	conn, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, fmt.Errorf("open database: %w", err)
	}

	conn.SetMaxOpenConns(1) // SQLite doesn't handle concurrent writes well

	if err := conn.Ping(); err != nil {
		return nil, fmt.Errorf("ping database: %w", err)
	}

	d := &DB{conn: conn}
	if err := d.migrate(); err != nil {
		return nil, fmt.Errorf("migrate: %w", err)
	}

	return d, nil
}

func (d *DB) Close() error {
	return d.conn.Close()
}

func (d *DB) migrate() error {
	_, err := d.conn.Exec(`
		CREATE TABLE IF NOT EXISTS clips (
			id           TEXT PRIMARY KEY,
			type         TEXT NOT NULL,
			filename     TEXT,
			size_bytes   INTEGER NOT NULL DEFAULT 0,
			status       TEXT NOT NULL DEFAULT '` + ClipStatusReady + `',
			created_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
			expires_at   DATETIME NOT NULL,
			storage_path TEXT NOT NULL DEFAULT ''
		)
	`)
	if err != nil {
		return err
	}

	_, err = d.conn.Exec(`
		CREATE TABLE IF NOT EXISTS devices (
			id           TEXT PRIMARY KEY,
			name         TEXT NOT NULL,
			platform     TEXT NOT NULL,
			last_seen_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
			created_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
		)
	`)
	if err != nil {
		return err
	}

	// In-place migration: add new columns to clips if they don't exist.
	// SQLite doesn't have ADD COLUMN IF NOT EXISTS, so we ignore errors from duplicate columns.
	d.conn.Exec(`ALTER TABLE clips ADD COLUMN target_device_id TEXT`)
	d.conn.Exec(`ALTER TABLE clips ADD COLUMN sender_device_id TEXT`)
	d.conn.Exec(`ALTER TABLE clips ADD COLUMN targeted_pending_at DATETIME`)
	d.conn.Exec(`ALTER TABLE clips ADD COLUMN consumed_at DATETIME`)

	return nil
}

func generateRandomID(length int) (string, error) {
	b := make([]byte, length)
	for i := range b {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(idChars))))
		if err != nil {
			return "", err
		}
		b[i] = idChars[n.Int64()]
	}
	return string(b), nil
}

func GenerateID() (string, error) {
	return generateRandomID(idLength)
}

func GenerateDeviceID() (string, error) {
	return generateRandomID(deviceIDLength)
}

func (d *DB) CreateClip(clip *Clip) error {
	if clip.ID == "" {
		id, err := GenerateID()
		if err != nil {
			return fmt.Errorf("generate id: %w", err)
		}
		clip.ID = id
	}

	if clip.CreatedAt.IsZero() {
		clip.CreatedAt = time.Now().UTC()
	}

	_, err := d.conn.Exec(`
		INSERT INTO clips (id, type, filename, size_bytes, status, created_at, expires_at, storage_path, target_device_id, sender_device_id, targeted_pending_at, consumed_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, clip.ID, clip.Type, clip.Filename, clip.SizeBytes, clip.Status, clip.CreatedAt, clip.ExpiresAt, clip.StoragePath, clip.TargetDeviceID, clip.SenderDeviceID, clip.TargetedPendingAt, clip.ConsumedAt)
	return err
}

func (d *DB) GetClipByID(id string) (*Clip, error) {
	clip := &Clip{}
	err := d.conn.QueryRow(`
		SELECT id, type, filename, size_bytes, status, created_at, expires_at, storage_path, target_device_id, sender_device_id, targeted_pending_at, consumed_at
		FROM clips WHERE id = ?
	`, id).Scan(&clip.ID, &clip.Type, &clip.Filename, &clip.SizeBytes, &clip.Status, &clip.CreatedAt, &clip.ExpiresAt, &clip.StoragePath, &clip.TargetDeviceID, &clip.SenderDeviceID, &clip.TargetedPendingAt, &clip.ConsumedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return clip, nil
}

func (d *DB) GetLatestClip() (*Clip, error) {
	clip := &Clip{}
	err := d.conn.QueryRow(`
		SELECT id, type, filename, size_bytes, status, created_at, expires_at, storage_path, target_device_id, sender_device_id, targeted_pending_at, consumed_at
		FROM clips WHERE expires_at > ? AND status = ?
		ORDER BY created_at DESC LIMIT 1
	`, time.Now().UTC(), ClipStatusReady).Scan(&clip.ID, &clip.Type, &clip.Filename, &clip.SizeBytes, &clip.Status, &clip.CreatedAt, &clip.ExpiresAt, &clip.StoragePath, &clip.TargetDeviceID, &clip.SenderDeviceID, &clip.TargetedPendingAt, &clip.ConsumedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return clip, nil
}

func (d *DB) ListClips() ([]*Clip, error) {
	rows, err := d.conn.Query(`
		SELECT id, type, filename, size_bytes, status, created_at, expires_at, storage_path, target_device_id, sender_device_id, targeted_pending_at, consumed_at
		FROM clips ORDER BY created_at DESC
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var clips []*Clip
	for rows.Next() {
		clip := &Clip{}
		if err := rows.Scan(&clip.ID, &clip.Type, &clip.Filename, &clip.SizeBytes, &clip.Status, &clip.CreatedAt, &clip.ExpiresAt, &clip.StoragePath, &clip.TargetDeviceID, &clip.SenderDeviceID, &clip.TargetedPendingAt, &clip.ConsumedAt); err != nil {
			return nil, err
		}
		clips = append(clips, clip)
	}
	return clips, rows.Err()
}

func (d *DB) DeleteClip(id string) error {
	_, err := d.conn.Exec(`DELETE FROM clips WHERE id = ?`, id)
	return err
}

func (d *DB) UpdateClip(id string, status string, sizeBytes int64, storagePath string, targetedPendingAt *time.Time) error {
	_, err := d.conn.Exec(`UPDATE clips SET status = ?, size_bytes = ?, storage_path = ?, targeted_pending_at = ? WHERE id = ?`,
		status, sizeBytes, storagePath, targetedPendingAt, id)
	return err
}

// GetExpiredClips returns all clips where expires_at < now (both ready and uploading).
func (d *DB) GetExpiredClips() ([]*Clip, error) {
	rows, err := d.conn.Query(`
		SELECT id, type, filename, size_bytes, status, created_at, expires_at, storage_path, target_device_id, sender_device_id, targeted_pending_at, consumed_at
		FROM clips WHERE expires_at < ?
	`, time.Now().UTC())
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var clips []*Clip
	for rows.Next() {
		clip := &Clip{}
		if err := rows.Scan(&clip.ID, &clip.Type, &clip.Filename, &clip.SizeBytes, &clip.Status, &clip.CreatedAt, &clip.ExpiresAt, &clip.StoragePath, &clip.TargetDeviceID, &clip.SenderDeviceID, &clip.TargetedPendingAt, &clip.ConsumedAt); err != nil {
			return nil, err
		}
		clips = append(clips, clip)
	}
	return clips, rows.Err()
}

// StorageStats holds aggregate info about stored clips.
type StorageStats struct {
	ClipCount        int   `json:"clip_count"`
	StorageUsedBytes int64 `json:"storage_used_bytes"`
}

// ListQueueClips returns unconsumed, queue-visible, non-expired clips visible to the given device.
// Queue-visible clips are untargeted ready clips plus targeted fallback clips addressed to deviceID.
// Results are newest first.
func (d *DB) ListQueueClips(deviceID string) ([]*Clip, error) {
	rows, err := d.conn.Query(`
		SELECT id, type, filename, size_bytes, status, created_at, expires_at, storage_path, target_device_id, sender_device_id, targeted_pending_at, consumed_at
		FROM clips
		WHERE consumed_at IS NULL
		  AND expires_at > ?
		  AND (
		    (status = ? AND target_device_id IS NULL)
		    OR (status = ? AND target_device_id = ?)
		  )
		ORDER BY created_at DESC
	`, time.Now().UTC(), ClipStatusReady, ClipStatusTargetedFallback, deviceID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var clips []*Clip
	for rows.Next() {
		clip := &Clip{}
		if err := rows.Scan(&clip.ID, &clip.Type, &clip.Filename, &clip.SizeBytes, &clip.Status, &clip.CreatedAt, &clip.ExpiresAt, &clip.StoragePath, &clip.TargetDeviceID, &clip.SenderDeviceID, &clip.TargetedPendingAt, &clip.ConsumedAt); err != nil {
			return nil, err
		}
		clips = append(clips, clip)
	}
	return clips, rows.Err()
}

// ListPendingTargetedClips returns non-expired, unconsumed targeted_pending
// clips addressed to the given device. Results are oldest first so reconnect
// replay preserves original send order.
func (d *DB) ListPendingTargetedClips(deviceID string) ([]*Clip, error) {
	rows, err := d.conn.Query(`
		SELECT id, type, filename, size_bytes, status, created_at, expires_at, storage_path, target_device_id, sender_device_id, targeted_pending_at, consumed_at
		FROM clips
		WHERE consumed_at IS NULL
		  AND expires_at > ?
		  AND status = ?
		  AND target_device_id = ?
		ORDER BY created_at ASC
	`, time.Now().UTC(), ClipStatusTargetedPending, deviceID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var clips []*Clip
	for rows.Next() {
		clip := &Clip{}
		if err := rows.Scan(&clip.ID, &clip.Type, &clip.Filename, &clip.SizeBytes, &clip.Status, &clip.CreatedAt, &clip.ExpiresAt, &clip.StoragePath, &clip.TargetDeviceID, &clip.SenderDeviceID, &clip.TargetedPendingAt, &clip.ConsumedAt); err != nil {
			return nil, err
		}
		clips = append(clips, clip)
	}
	return clips, rows.Err()
}

// ConsumeClip atomically marks an untargeted clip as consumed. Returns true if
// the clip was successfully claimed (i.e. it was not already consumed).
// Returns false if another caller already consumed it.
func (d *DB) ConsumeClip(id string) (bool, error) {
	res, err := d.conn.Exec(`
		UPDATE clips SET consumed_at = ? WHERE id = ? AND consumed_at IS NULL
	`, time.Now().UTC(), id)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	return n > 0, nil
}

// ConsumeTargetedClip atomically marks a targeted clip as consumed by its
// addressed device and moves it into the delivered state. Returns true if the
// addressed device successfully claimed it. Returns false if the clip was
// already consumed or the requesting device does not match the target.
func (d *DB) ConsumeTargetedClip(id string, deviceID string) (bool, error) {
	res, err := d.conn.Exec(`
		UPDATE clips
		SET consumed_at = ?, status = ?, targeted_pending_at = NULL
		WHERE id = ? AND consumed_at IS NULL AND target_device_id = ?
	`, time.Now().UTC(), ClipStatusTargetedDelivered, id, deviceID)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	return n > 0, nil
}

// GetConsumedClips returns clips where consumed_at is not null and consumed_at is older than the given threshold.
func (d *DB) GetConsumedClips(olderThan time.Duration) ([]*Clip, error) {
	cutoff := time.Now().UTC().Add(-olderThan)
	rows, err := d.conn.Query(`
		SELECT id, type, filename, size_bytes, status, created_at, expires_at, storage_path, target_device_id, sender_device_id, targeted_pending_at, consumed_at
		FROM clips WHERE consumed_at IS NOT NULL AND consumed_at < ?
	`, cutoff)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var clips []*Clip
	for rows.Next() {
		clip := &Clip{}
		if err := rows.Scan(&clip.ID, &clip.Type, &clip.Filename, &clip.SizeBytes, &clip.Status, &clip.CreatedAt, &clip.ExpiresAt, &clip.StoragePath, &clip.TargetDeviceID, &clip.SenderDeviceID, &clip.TargetedPendingAt, &clip.ConsumedAt); err != nil {
			return nil, err
		}
		clips = append(clips, clip)
	}
	return clips, rows.Err()
}

// FallbackTargetedClips atomically moves stale targeted_pending clips into
// targeted_fallback and returns the number of rows transitioned.
func (d *DB) FallbackTargetedClips(olderThan time.Duration) (int64, error) {
	cutoff := time.Now().UTC().Add(-olderThan)
	res, err := d.conn.Exec(`
		UPDATE clips
		SET status = ?, targeted_pending_at = NULL
		WHERE consumed_at IS NULL
		  AND status = ?
		  AND target_device_id IS NOT NULL
		  AND targeted_pending_at IS NOT NULL
		  AND targeted_pending_at < ?
	`, ClipStatusTargetedFallback, ClipStatusTargetedPending, cutoff)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// GetStaleTargetedClips returns targeted_pending clips old enough to fall back.
func (d *DB) GetStaleTargetedClips(olderThan time.Duration) ([]*Clip, error) {
	cutoff := time.Now().UTC().Add(-olderThan)
	rows, err := d.conn.Query(`
		SELECT id, type, filename, size_bytes, status, created_at, expires_at, storage_path, target_device_id, sender_device_id, targeted_pending_at, consumed_at
		FROM clips
		WHERE consumed_at IS NULL
		  AND status = ?
		  AND target_device_id IS NOT NULL
		  AND targeted_pending_at IS NOT NULL
		  AND targeted_pending_at < ?
		ORDER BY targeted_pending_at ASC
	`, ClipStatusTargetedPending, cutoff)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var clips []*Clip
	for rows.Next() {
		clip := &Clip{}
		if err := rows.Scan(&clip.ID, &clip.Type, &clip.Filename, &clip.SizeBytes, &clip.Status, &clip.CreatedAt, &clip.ExpiresAt, &clip.StoragePath, &clip.TargetDeviceID, &clip.SenderDeviceID, &clip.TargetedPendingAt, &clip.ConsumedAt); err != nil {
			return nil, err
		}
		clips = append(clips, clip)
	}
	return clips, rows.Err()
}

// GetStorageStats returns count and total size of all clips.
func (d *DB) GetStorageStats() (*StorageStats, error) {
	stats := &StorageStats{}
	err := d.conn.QueryRow(`
		SELECT COUNT(*), COALESCE(SUM(size_bytes), 0)
		FROM clips
	`).Scan(&stats.ClipCount, &stats.StorageUsedBytes)
	if err != nil {
		return nil, err
	}
	return stats, nil
}

// RegisterDevice inserts a new device or returns the existing one if (name, platform) already exists.
// In both cases last_seen_at is bumped to now.
func (d *DB) RegisterDevice(name, platform string) (*Device, error) {
	now := time.Now().UTC()

	// Check for existing device with same name+platform
	existing := &Device{}
	err := d.conn.QueryRow(`
		SELECT id, name, platform, last_seen_at, created_at
		FROM devices WHERE name = ? AND platform = ?
	`, name, platform).Scan(&existing.ID, &existing.Name, &existing.Platform, &existing.LastSeenAt, &existing.CreatedAt)

	if err == nil {
		// Bump last_seen_at
		_, err = d.conn.Exec(`UPDATE devices SET last_seen_at = ? WHERE id = ?`, now, existing.ID)
		if err != nil {
			return nil, fmt.Errorf("bump last_seen_at: %w", err)
		}
		existing.LastSeenAt = now
		return existing, nil
	}
	if err != sql.ErrNoRows {
		return nil, err
	}

	// Create new device
	id, err := GenerateDeviceID()
	if err != nil {
		return nil, fmt.Errorf("generate device id: %w", err)
	}

	_, err = d.conn.Exec(`
		INSERT INTO devices (id, name, platform, last_seen_at, created_at)
		VALUES (?, ?, ?, ?, ?)
	`, id, name, platform, now, now)
	if err != nil {
		return nil, fmt.Errorf("insert device: %w", err)
	}

	return &Device{
		ID:         id,
		Name:       name,
		Platform:   platform,
		LastSeenAt: now,
		CreatedAt:  now,
	}, nil
}

// ListDevices returns all devices seen in the last 30 days.
func (d *DB) ListDevices() ([]*Device, error) {
	cutoff := time.Now().UTC().Add(-30 * 24 * time.Hour)
	rows, err := d.conn.Query(`
		SELECT id, name, platform, last_seen_at, created_at
		FROM devices WHERE last_seen_at > ?
		ORDER BY last_seen_at DESC
	`, cutoff)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var devices []*Device
	for rows.Next() {
		dev := &Device{}
		if err := rows.Scan(&dev.ID, &dev.Name, &dev.Platform, &dev.LastSeenAt, &dev.CreatedAt); err != nil {
			return nil, err
		}
		devices = append(devices, dev)
	}
	return devices, rows.Err()
}
