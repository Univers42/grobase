<?php

declare(strict_types=1);

namespace App\Core;

/**
 * Base Model
 * Provides common database operations for all models.
 */
abstract class Model
{
    protected Database $db;
    protected string $table;

    public function __construct()
    {
        $this->db = Database::getInstance();
    }

    /**
     * Find a record by ID.
     */
    public function findById(int $id): ?array
    {
        $stmt = $this->db->query(
            "SELECT * FROM {$this->table} WHERE id = :id LIMIT 1",
            ['id' => $id]
        );
        $result = $stmt->fetch();
        return $result ?: null;
    }

    /**
     * Find all records.
     */
    public function findAll(string $orderBy = 'id', string $direction = 'DESC'): array
    {
        $direction = strtoupper($direction) === 'ASC' ? 'ASC' : 'DESC';
        $stmt = $this->db->query(
            "SELECT * FROM {$this->table} ORDER BY {$orderBy} {$direction}"
        );
        return $stmt->fetchAll();
    }

    /**
     * Find records with pagination.
     */
    public function paginate(int $page = 1, int $perPage = 5, string $orderBy = 'created_at', string $direction = 'DESC'): array
    {
        $direction = strtoupper($direction) === 'ASC' ? 'ASC' : 'DESC';
        $offset = ($page - 1) * $perPage;

        // Total count
        $countStmt = $this->db->query("SELECT COUNT(*) as total FROM {$this->table}");
        $total = (int)$countStmt->fetch()['total'];

        // Records
        $stmt = $this->db->query(
            "SELECT * FROM {$this->table} ORDER BY {$orderBy} {$direction} LIMIT :limit OFFSET :offset",
            ['limit' => $perPage, 'offset' => $offset]
        );
        $records = $stmt->fetchAll();

        return [
            'data'       => $records,
            'total'      => $total,
            'page'       => $page,
            'perPage'    => $perPage,
            'totalPages' => (int)ceil($total / $perPage),
        ];
    }

    /**
     * Insert a new record.
     */
    public function create(array $data): int
    {
        $columns = implode(', ', array_keys($data));
        $placeholders = implode(', ', array_map(fn($k) => ":{$k}", array_keys($data)));

        $this->db->query(
            "INSERT INTO {$this->table} ({$columns}) VALUES ({$placeholders})",
            $data
        );

        return (int)$this->db->lastInsertId();
    }

    /**
     * Update a record by ID.
     */
    public function update(int $id, array $data): bool
    {
        $sets = implode(', ', array_map(fn($k) => "{$k} = :{$k}", array_keys($data)));
        $data['id'] = $id;

        $stmt = $this->db->query(
            "UPDATE {$this->table} SET {$sets} WHERE id = :id",
            $data
        );

        return $stmt->rowCount() > 0;
    }

    /**
     * Delete a record by ID.
     */
    public function delete(int $id): bool
    {
        $stmt = $this->db->query(
            "DELETE FROM {$this->table} WHERE id = :id",
            ['id' => $id]
        );
        return $stmt->rowCount() > 0;
    }
}
