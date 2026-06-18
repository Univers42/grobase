/**
 * SearchBar - Global user search component
 * Searches users by name/username with role-based visibility
 */

import { useState, useEffect, useRef, useCallback } from 'react';
import { useNavigate } from 'react-router-dom';
import { usePortalAuth } from '../../../portal_dashboard/PortalAuthContext';
import type { SearchResult } from './types';
import { searchUsers, canViewUser } from './searchService';
import './SearchBar.css';

interface SearchBarProps {
  placeholder?: string;
  onSelectUser?: (user: SearchResult) => void;
}

export function SearchBar({
  placeholder = 'Rechercher un utilisateur...',
  onSelectUser,
}: Readonly<SearchBarProps>) {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<SearchResult[]>([]);
  const [loading, setLoading] = useState(false);
  const [isOpen, setIsOpen] = useState(false);
  const [focusedIndex, setFocusedIndex] = useState(-1);
  const inputRef = useRef<HTMLInputElement>(null);
  const dropdownRef = useRef<HTMLDivElement>(null);
  const navigate = useNavigate();
  const { user: currentUser } = usePortalAuth();
  const showResults = loading === false && results.length > 0;
  const showEmpty = loading === false && results.length === 0;
  const resultCountText = `${results.length} résultat${results.length > 1 ? 's' : ''}`;
  const emptyMessage = `Aucun utilisateur trouvé pour "${query}"`;

  // Debounced search
  useEffect(() => {
    if (query.length < 2) {
      setResults([]);
      setIsOpen(false);
      return;
    }

    const timeoutId = setTimeout(async () => {
      setLoading(true);
      try {
        const searchResults = await searchUsers(query);
        // Filter results based on visibility rules
        const visibleResults = searchResults.filter((user: SearchResult) =>
          canViewUser(currentUser?.role, user.role),
        );
        setResults(visibleResults);
        setIsOpen(true);
      } catch (error) {
        console.error('Search error:', error);
        setResults([]);
      } finally {
        setLoading(false);
      }
    }, 300);

    return () => clearTimeout(timeoutId);
  }, [query, currentUser?.role]);

  // Keyboard navigation
  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      if (!isOpen) return;

      switch (e.key) {
        case 'ArrowDown':
          e.preventDefault();
          setFocusedIndex((prev) => Math.min(prev + 1, results.length - 1));
          break;
        case 'ArrowUp':
          e.preventDefault();
          setFocusedIndex((prev) => Math.max(prev - 1, 0));
          break;
        case 'Enter':
          e.preventDefault();
          if (focusedIndex >= 0 && results[focusedIndex]) {
            handleSelectUser(results[focusedIndex]);
          }
          break;
        case 'Escape':
          setIsOpen(false);
          setFocusedIndex(-1);
          break;
      }
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [isOpen, results, focusedIndex],
  );

  // Close on click outside
  useEffect(() => {
    const handleClickOutside = (e: MouseEvent) => {
      const target = e.target;
      if (!(target instanceof Node)) return;

      if (
        dropdownRef.current &&
        !dropdownRef.current.contains(target) &&
        inputRef.current &&
        !inputRef.current.contains(target)
      ) {
        setIsOpen(false);
      }
    };

    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  // Keyboard shortcut to focus
  useEffect(() => {
    const handleGlobalKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
        e.preventDefault();
        inputRef.current?.focus();
      }
    };

    document.addEventListener('keydown', handleGlobalKeyDown);
    return () => document.removeEventListener('keydown', handleGlobalKeyDown);
  }, []);

  const handleSelectUser = (user: SearchResult) => {
    setIsOpen(false);
    setQuery('');
    setFocusedIndex(-1);

    if (onSelectUser) {
      onSelectUser(user);
    } else {
      // Navigate to user profile
      navigate(`/portal/profile/${user.id}`);
    }
  };

  const highlightMatch = (text: string, query: string) => {
    if (!query) return text;
    const regex = new RegExp(`(${query})`, 'gi');
    const parts = text.split(regex);
    return parts.map((part) =>
      regex.test(part) ? (
        <mark key={part} className="search-result-highlight">
          {part}
        </mark>
      ) : (
        part
      ),
    );
  };

  const getRoleEmoji = (role: string) => {
    switch (role) {
      case 'superadmin':
        return '👑';
      case 'admin':
        return '🛡️';
      case 'employee':
        return '👷';
      case 'customer':
        return '👤';
      default:
        return '👤';
    }
  };

  const getResultItemClassName = (index: number) =>
    index === focusedIndex ? 'search-result-item search-result-item--focused' : 'search-result-item';

  const getRoleClassName = (role: string) => `search-result-role search-result-role--${role}`;

  return (
    <div className="search-bar">
      <div className="search-bar-input-wrapper">
        <input
          ref={inputRef}
          id="user-search"
          name="user-search"
          type="text"
          className="search-bar-input"
          placeholder={placeholder}
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          onKeyDown={handleKeyDown}
          onFocus={() => query.length >= 2 && setIsOpen(true)}
          aria-label="Rechercher des utilisateurs"
          aria-controls="search-results"
          autoComplete="off"
        />
        <SearchIcon className="search-bar-icon" />

        {query ? (
          <button
            className="search-bar-clear"
            onClick={() => {
              setQuery('');
              setIsOpen(false);
            }}
            aria-label="Effacer la recherche"
          >
            ✕
          </button>
        ) : (
          <span className="search-bar-shortcut">⌘K</span>
        )}
      </div>

      {isOpen && (
        <div ref={dropdownRef} className="search-dropdown" id="search-results">
          {loading && (
            <div className="search-loading">
              <span className="search-loading-spinner" />
              <span>Recherche...</span>
            </div>
          )}
          {showResults && (
            <div className="search-results-group">
              <div className="search-dropdown-header">
                <span className="search-dropdown-title">Utilisateurs</span>
                <span className="search-dropdown-count">{resultCountText}</span>
              </div>
              <div className="search-results-list">
                {results.map((user, index) => (
                  <button
                    type="button"
                    key={user.id}
                    className={getResultItemClassName(index)}
                    onClick={() => handleSelectUser(user)}
                    onMouseEnter={() => setFocusedIndex(index)}
                  >
                    <div className="search-result-avatar">{getRoleEmoji(user.role)}</div>
                    <div className="search-result-info">
                      <div className="search-result-name">{highlightMatch(user.name, query)}</div>
                      <div className="search-result-meta">
                        <span>@{highlightMatch(user.username, query)}</span>
                        <span className={getRoleClassName(user.role)}>{user.role}</span>
                      </div>
                    </div>
                    <span className="search-result-arrow">→</span>
                  </button>
                ))}
              </div>
            </div>
          )}
          {showEmpty && (
            <div className="search-empty">
              <div className="search-empty-icon">🔍</div>
              <p className="search-empty-text">{emptyMessage}</p>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function SearchIcon({ className }: Readonly<{ className?: string }>) {
  return (
    <svg
      className={className}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
    >
      <circle cx="11" cy="11" r="8" />
      <path d="M21 21l-4.35-4.35" />
    </svg>
  );
}
