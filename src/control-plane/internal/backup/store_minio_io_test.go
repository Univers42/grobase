/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   store_minio_io_test.go                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:40:29 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:40:30 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package backup

import "testing"

// TestObjectURL pins the URL composition: scheme from secure, host=endpoint,
// then bucket/prefix/key with the leading slash trimmed off the key. A leading
// "/" on the key must NOT produce a double slash after the prefix.
func TestObjectURL(t *testing.T) {
	cases := []struct {
		name     string
		secure   bool
		endpoint string
		bucket   string
		prefix   string
		key      string
		want     string
	}{
		{
			name:     "http plain key",
			secure:   false,
			endpoint: "minio:9000",
			bucket:   "baas",
			prefix:   "backups/",
			key:      "tenant-1/abc",
			want:     "http://minio:9000/baas/backups/tenant-1/abc",
		},
		{
			name:     "https secure",
			secure:   true,
			endpoint: "s3.example.com",
			bucket:   "baas",
			prefix:   "backups/",
			key:      "t/b",
			want:     "https://s3.example.com/baas/backups/t/b",
		},
		{
			name:     "leading slash on key is trimmed",
			secure:   false,
			endpoint: "minio:9000",
			bucket:   "baas",
			prefix:   "backups/",
			key:      "/tenant-1/abc",
			want:     "http://minio:9000/baas/backups/tenant-1/abc",
		},
		{
			name:     "custom prefix and bucket",
			secure:   false,
			endpoint: "host:1",
			bucket:   "mybucket",
			prefix:   "p/",
			key:      "k",
			want:     "http://host:1/mybucket/p/k",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := &MinIOStore{secure: tc.secure, endpoint: tc.endpoint, bucket: tc.bucket, prefix: tc.prefix}
			if got := s.objectURL(tc.key); got != tc.want {
				t.Fatalf("objectURL(%q) = %q, want %q", tc.key, got, tc.want)
			}
		})
	}
}

// TestScheme asserts secure toggles https/http.
func TestScheme(t *testing.T) {
	if got := (&MinIOStore{secure: true}).scheme(); got != "https" {
		t.Fatalf("secure scheme = %q, want https", got)
	}
	if got := (&MinIOStore{secure: false}).scheme(); got != "http" {
		t.Fatalf("insecure scheme = %q, want http", got)
	}
}

// TestNormalizePrefix pins the prefix defaulting + single-trailing-slash rule.
func TestNormalizePrefix(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"", "backups/"},
		{"backups", "backups/"},
		{"backups/", "backups/"},
		{"custom/p", "custom/p/"},
		{"custom/p/", "custom/p/"},
	}
	for _, tc := range cases {
		if got := normalizePrefix(tc.in); got != tc.want {
			t.Fatalf("normalizePrefix(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// TestMinioRegion asserts the env default (us-east-1) and override.
func TestMinioRegion(t *testing.T) {
	t.Setenv("MINIO_REGION", "")
	if got := minioRegion(); got != "us-east-1" {
		t.Fatalf("default region = %q, want us-east-1", got)
	}
	t.Setenv("MINIO_REGION", "eu-central-1")
	if got := minioRegion(); got != "eu-central-1" {
		t.Fatalf("override region = %q, want eu-central-1", got)
	}
}
