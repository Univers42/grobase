package tenants

import (
	"fmt"
	"testing"
)

// BenchmarkVerifyKeyHashFast measures one verify against the fast (SHA-256)
// scheme new keys are minted with. This is the number that decides H-4: if a
// verify costs microseconds, API_KEY_VERIFY_CACHE_TTL_MS is a revocation-latency
// knob and not a capacity one, and it can be lowered freely.
func BenchmarkVerifyKeyHashFast(b *testing.B) {
	h := newKeyHasher()
	stored := hashPayloadFast("bench-payload", "mbkbenchprefix00")
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if !h.verifyKeyHash("bench-payload", "mbkbenchprefix00", stored) {
			b.Fatal("fast verify rejected a correct payload")
		}
	}
}

// BenchmarkVerifyKeyHashArgon2 measures one verify against the legacy argon2id
// scheme (m=32 MiB, t=1, p=2) that keys minted before the fast-hash migration
// still carry. It is the ceiling the 60 s TTL was chosen to stay under.
func BenchmarkVerifyKeyHashArgon2(b *testing.B) {
	h := newKeyHasher()
	stored := h.hashPayload("bench-payload", "mbkbenchprefix00")
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if !h.verifyKeyHash("bench-payload", "mbkbenchprefix00", stored) {
			b.Fatal("argon2 verify rejected a correct payload")
		}
	}
}

// BenchmarkVerifyKeyHashArgon2Parallel measures the SUSTAINED argon2id verify
// rate through the hasher's semaphore at several ARGON2_MAX_CONCURRENT
// settings. Concurrency is bounded on purpose (each computation holds 32 MiB, so
// unbounded fan-out OOM-killed tenant-control — see keyHasher's doc), which is
// why the aggregate rate, not the single-verify latency, is the real capacity
// limit: ns/op here is wall time per verify across b.N, so verify/s = 1e9/ns.
func BenchmarkVerifyKeyHashArgon2Parallel(b *testing.B) {
	for _, slots := range []int{1, 2, 4} {
		b.Run(fmt.Sprintf("slots=%d", slots), func(b *testing.B) {
			h := &keyHasher{slots: make(chan struct{}, slots)}
			stored := h.hashPayload("bench-payload", "mbkbenchprefix00")
			b.SetParallelism(8)
			b.ResetTimer()
			b.RunParallel(func(pb *testing.PB) {
				for pb.Next() {
					if !h.verifyKeyHash("bench-payload", "mbkbenchprefix00", stored) {
						b.Fatal("argon2 verify rejected a correct payload")
					}
				}
			})
		})
	}
}
