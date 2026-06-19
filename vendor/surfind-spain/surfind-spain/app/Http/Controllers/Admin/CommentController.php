<?php

namespace App\Http\Controllers\Admin;

use App\Http\Controllers\Controller;
use App\Models\Comment;
use Illuminate\Http\RedirectResponse;

class CommentController extends Controller
{
    public function destroy(Comment $comment): RedirectResponse
    {
        $comment->update([
            'published' => false,
        ]);

        return back()->with('status', 'El comentario ha sido ocultado.');
    }
}
