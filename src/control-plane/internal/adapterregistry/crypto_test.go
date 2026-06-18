package adapterregistry

import "testing"

func TestEncryptDecryptRoundTrip(t *testing.T) {
	enc, err := NewEncryptor("test-master-key-1234567890")
	if err != nil {
		t.Fatalf("NewEncryptor: %v", err)
	}

	plaintext := "postgresql://user:pass@db.internal:5432/tenant_42?sslmode=require"
	payload, err := enc.Encrypt(plaintext)
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	// Sizing must match the Node CryptoService layout exactly.
	if len(payload.Salt) != saltLength {
		t.Errorf("salt length = %d, want %d", len(payload.Salt), saltLength)
	}
	if len(payload.IV) != ivLength {
		t.Errorf("iv length = %d, want %d", len(payload.IV), ivLength)
	}
	if len(payload.Tag) != authTagLen {
		t.Errorf("tag length = %d, want %d", len(payload.Tag), authTagLen)
	}

	got, err := enc.Decrypt(payload)
	if err != nil {
		t.Fatalf("Decrypt: %v", err)
	}
	if got != plaintext {
		t.Errorf("round trip mismatch: got %q want %q", got, plaintext)
	}
}

func TestDecryptRejectsTamperedTag(t *testing.T) {
	enc, _ := NewEncryptor("test-master-key-1234567890")
	payload, _ := enc.Encrypt("secret")
	payload.Tag[0] ^= 0xFF
	if _, err := enc.Decrypt(payload); err == nil {
		t.Fatal("expected decrypt to fail on tampered tag")
	}
}

func TestNewEncryptorRejectsShortKey(t *testing.T) {
	if _, err := NewEncryptor("short"); err == nil {
		t.Fatal("expected error for short master key")
	}
}
