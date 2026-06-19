<?php

namespace App\Http\Controllers;

use App\Models\Beach;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;

class CommentController extends Controller
{
    public function store(Request $request, Beach $beach): RedirectResponse
    {
        abort_unless($beach->status === 'published', 404);

        $validated = $request->validate([
            'content' => ['required', 'string', 'min:3', 'max:1000'],
        ]);

        $beach->comments()->create([
            'user_id' => $request->user()->id,
            'content' => $validated['content'],
            'published' => true,
        ]);

        return redirect(route('beaches.show', $beach).'#comentarios');
    }
}
