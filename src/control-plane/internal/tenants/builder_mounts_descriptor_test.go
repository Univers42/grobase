package tenants

import (
	"encoding/json"
	"net/http"
	"reflect"
	"testing"
	"time"
)

const mountUUID = "0b0e6c1e-6c4f-4d0a-9d5e-2f6a1c3b9e71"

func TestDescribeMountRelaysTheCallersDescriptor(t *testing.T) {
	descriptor := map[string]any{"id": mountUUID, "engine": "sqlite", "location": "file", "file": "app.db", "tls": "n/a"}
	for name, mount := range map[string]func(*http.ServeMux, BuilderDeps){"MountMountList": MountMountList, "MountBuilder": MountBuilder} {
		t.Run(name, func(t *testing.T) {
			svc := &Service{verifyC: testCache(time.Minute, 16)}
			key := seedKey(t, svc, "acme", "read")
			adapter, calls := fakeMountRegistry(t, descriptor)
			mux := http.NewServeMux()
			mount(mux, BuilderDeps{Svc: svc, Adapter: adapter})

			rec := serve(t, mux, http.MethodGet, mountsPath+"/"+mountUUID+"/descriptor", key)

			if rec.Code != http.StatusOK {
				t.Fatalf("status = %d, want 200; body %s", rec.Code, rec.Body)
			}
			var got map[string]any
			if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil || !reflect.DeepEqual(got, descriptor) {
				t.Errorf("body = %s (%v), want %v", rec.Body, err, descriptor)
			}
			want := []registryCall{{http.MethodGet, "/databases/" + mountUUID + "/descriptor", "acme"}}
			if c := calls(); !reflect.DeepEqual(c, want) {
				t.Errorf("adapter-registry calls = %+v, want %+v", c, want)
			}
		})
	}
}

func TestDescribeMountRefusesBeforeTheRegistry(t *testing.T) {
	svc := &Service{verifyC: testCache(time.Minute, 16)}
	readKey := seedKey(t, svc, "acme", "read")
	writeOnlyKey := seedKey(t, svc, "acme", "write")
	adapter, calls := fakeMountRegistry(t, nil)
	mux := http.NewServeMux()
	MountMountList(mux, BuilderDeps{Svc: svc, Adapter: adapter})

	cases := []struct {
		name, path, key string
		want            int
	}{
		{"no credential", mountsPath + "/" + mountUUID + "/descriptor", "", http.StatusUnauthorized},
		{"no read scope", mountsPath + "/" + mountUUID + "/descriptor", writeOnlyKey, http.StatusForbidden},
		{"not a uuid", mountsPath + "/m1/descriptor", readKey, http.StatusNotFound},
		{"escaped slash splices no path", mountsPath + "/x%2F..%2F..%2Fdatabases/descriptor", readKey, http.StatusNotFound},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if rec := serve(t, mux, http.MethodGet, c.path, c.key); rec.Code != c.want {
				t.Errorf("GET %s = %d, want %d; body %s", c.path, rec.Code, c.want, rec.Body)
			}
		})
	}
	if c := calls(); len(c) != 0 {
		t.Errorf("refused requests reached the adapter-registry: %+v", c)
	}
}
