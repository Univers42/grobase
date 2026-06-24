/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   store_minio_sig.go                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:40:36 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:40:38 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package backup

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// signedRequest builds an AWS SigV4-signed S3 request (stdlib-only).
func (s *MinIOStore) signedRequest(ctx context.Context, method, key string, body []byte, payloadHash string) (*http.Request, error) {
	u, err := url.Parse(s.objectURL(key))
	if err != nil {
		return nil, fmt.Errorf("backup: build object url: %w", err)
	}
	var rdr io.Reader
	if body != nil {
		rdr = strings.NewReader(string(body))
	}
	req, err := http.NewRequestWithContext(ctx, method, u.String(), rdr)
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	amzDate := now.Format("20060102T150405Z")
	dateStamp := now.Format("20060102")

	req.Header.Set("Host", u.Host)
	req.Header.Set("X-Amz-Date", amzDate)
	req.Header.Set("X-Amz-Content-Sha256", payloadHash)
	req.Header.Set("Authorization", s.authHeader(sigInput{method: method, u: u, amzDate: amzDate, dateStamp: dateStamp, payloadHash: payloadHash}))
	return req, nil
}

// sigInput groups the per-request SigV4 signing inputs: HTTP method, parsed URL,
// the amz date, the date stamp, and the payload hash.
type sigInput struct {
	method      string
	u           *url.URL
	amzDate     string
	dateStamp   string
	payloadHash string
}

// authHeader computes the SigV4 Authorization header value for one request: the
// canonical request -> string-to-sign -> HMAC chain (stdlib-only).
func (s *MinIOStore) authHeader(in sigInput) string {
	canonicalHeaders := fmt.Sprintf("host:%s\nx-amz-content-sha256:%s\nx-amz-date:%s\n", in.u.Host, in.payloadHash, in.amzDate)
	signedHeaders := "host;x-amz-content-sha256;x-amz-date"
	canonicalRequest := strings.Join([]string{in.method, in.u.EscapedPath(), "", canonicalHeaders, signedHeaders, in.payloadHash}, "\n")

	scope := strings.Join([]string{in.dateStamp, s.region, "s3", "aws4_request"}, "/")
	crHash := sha256.Sum256([]byte(canonicalRequest))
	stringToSign := strings.Join([]string{"AWS4-HMAC-SHA256", in.amzDate, scope, hex.EncodeToString(crHash[:])}, "\n")

	sig := hmacSHA256(sigV4Key(s.secret, in.dateStamp, s.region, "s3"), []byte(stringToSign))
	return fmt.Sprintf("AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s",
		s.access, scope, signedHeaders, hex.EncodeToString(sig))
}

func hmacSHA256(key, data []byte) []byte {
	m := hmac.New(sha256.New, key)
	m.Write(data)
	return m.Sum(nil)
}

func sigV4Key(secret, dateStamp, region, service string) []byte {
	kDate := hmacSHA256([]byte("AWS4"+secret), []byte(dateStamp))
	kRegion := hmacSHA256(kDate, []byte(region))
	kService := hmacSHA256(kRegion, []byte(service))
	return hmacSHA256(kService, []byte("aws4_request"))
}
