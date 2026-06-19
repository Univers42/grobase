<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class Comment extends Model
{
    protected $fillable = [
        'user_id',
        'beach_id',
        'content',
        'published',
    ];

    protected function casts(): array
    {
        return [
            'published' => 'boolean',
        ];
    }

    public function beach()
    {
        return $this->belongsTo(Beach::class);
    }

    public function user()
    {
        return $this->belongsTo(User::class);
    }
}
