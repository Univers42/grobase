/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   store_select.go                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:40:44 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:40:45 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package backup

import (
	"fmt"
	"os"
)

// NewStoreFromEnv selects the artifact backend from the environment: a
// MinIOStore when MINIO_ENDPOINT and MINIO_ROOT_USER are set (the production
// compose vars pg-backup already uses), otherwise a LocalFileStore rooted at
// $BACKUP_DATA_DIR (default /var/lib/baas-artifacts). main.go consumes this.
func NewStoreFromEnv() (ArtifactStore, error) {
	if ep := os.Getenv("MINIO_ENDPOINT"); ep != "" && os.Getenv("MINIO_ROOT_USER") != "" {
		return NewMinIOStore(ep, os.Getenv("MINIO_ROOT_USER"), os.Getenv("MINIO_ROOT_PASSWORD"), "backups/")
	}
	dir := os.Getenv("BACKUP_DATA_DIR")
	if dir == "" {
		dir = "/var/lib/baas-artifacts"
	}
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return nil, fmt.Errorf("backup: create local artifact dir %q: %w", dir, err)
	}
	return NewLocalFileStore(dir), nil
}
