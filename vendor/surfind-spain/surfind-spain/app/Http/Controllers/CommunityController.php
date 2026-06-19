<?php

namespace App\Http\Controllers;

use App\Models\Beach;
use Illuminate\View\View;

class CommunityController extends Controller
{
    public function index(): View
    {
        $topBeaches = Beach::query()
            ->where('status', 'published')
            ->with(['location', 'coverImage'])
            ->withCount([
                'comments as published_comments_count' => fn ($query) => $query->where('published', true),
                'favoritedByUsers',
            ])
            ->orderByDesc('favorited_by_users_count')
            ->orderByDesc('published_comments_count')
            ->orderBy('name')
            ->limit(5)
            ->get();

        return view('community.index', [
            'topBeaches' => $topBeaches,
        ]);
    }
}
