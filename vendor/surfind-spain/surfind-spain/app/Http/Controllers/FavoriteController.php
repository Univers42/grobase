<?php

namespace App\Http\Controllers;

use App\Models\Beach;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;

class FavoriteController extends Controller
{
    public function store(Request $request, Beach $beach): RedirectResponse
    {
        abort_unless($beach->status === 'published', 404);

        $request->user()->favoriteBeaches()->syncWithoutDetaching([$beach->id]);

        return back();
    }

    public function destroy(Request $request, Beach $beach): RedirectResponse
    {
        abort_unless($beach->status === 'published', 404);

        $request->user()->favoriteBeaches()->detach($beach->id);

        return back();
    }
}
