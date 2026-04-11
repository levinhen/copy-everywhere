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

type Clip struct {
	ID          string    `json:"id"`
	Type        string    `json:"type"`
	Filename    *string   `json:"filename"`
	SizeBytes   int64     `json:"size_bytes"`
	Status      string    `json:"status"`
	CreatedAt   time.Time `json:"created_at"`
	ExpiresAt   time.Time `json:"expires_at"`
	StoragePath string    `json:"storage_path"`
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
			status       TEXT NOT NULL DEFAULT 'ready',
			created_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
			expires_at   DATETIME NOT NULL,
			storage_path TEXT NOT NULL DEFAULT ''
		)
	`)
	return err
}

func GenerateID() (string, error) {
	b := make([]byte, idLength)
	for i := range b {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(idChars))))
		if err != nil {
			return "", err
		}
		b[i] = idChars[n.Int64()]
	}
	return string(b), nil
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
		INSERT INTO clips (id, type, filename, size_bytes, status, created_at, expires_at, storage_path)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
	`, clip.ID, clip.Type, clip.Filename, clip.SizeBytes, clip.Status, clip.CreatedAt, clip.ExpiresAt, clip.StoragePath)
	return err
}

func (d *DB) GetClipByID(id string) (*Clip, error) {
	clip := &Clip{}
	err := d.conn.QueryRow(`
		SELECT id, type, filename, size_bytes, status, created_at, expires_at, storage_path
		FROM clips WHERE id = ?
	`, id).Scan(&clip.ID, &clip.Type, &clip.Filename, &clip.SizeBytes, &clip.Status, &clip.CreatedAt, &clip.ExpiresAt, &clip.StoragePath)
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
		SELECT id, type, filename, size_bytes, status, created_at, expires_at, storage_path
		FROM clips WHERE expires_at > ? AND status = 'ready'
		ORDER BY created_at DESC LIMIT 1
	`, time.Now().UTC()).Scan(&clip.ID, &clip.Type, &clip.Filename, &clip.SizeBytes, &clip.Status, &clip.CreatedAt, &clip.ExpiresAt, &clip.StoragePath)
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
		SELECT id, type, filename, size_bytes, status, created_at, expires_at, storage_path
		FROM clips ORDER BY created_at DESC
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var clips []*Clip
	for rows.Next() {
		clip := &Clip{}
		if err := rows.Scan(&clip.ID, &clip.Type, &clip.Filename, &clip.SizeBytes, &clip.Status, &clip.CreatedAt, &clip.ExpiresAt, &clip.StoragePath); err != nil {
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

func (d *DB) UpdateClip(id string, status string, sizeBytes int64, storagePath string) error {
	_, err := d.conn.Exec(`UPDATE clips SET status = ?, size_bytes = ?, storage_path = ? WHERE id = ?`,
		status, sizeBytes, storagePath, id)
	return err
}
