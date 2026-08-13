// Override Mintlify's search with custom modal
(function() {
  let modalOpen = false;
  let modal = null;

  // Create search modal
  function createModal() {
    if (modal) return modal;
    
    modal = document.createElement('div');
    modal.id = 'custom-search-modal';
    modal.innerHTML = `
      <div class="search-backdrop"></div>
      <div class="search-dialog">
        <div class="search-input-wrapper">
          <svg class="search-icon" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="11" cy="11" r="8"></circle>
            <path d="m21 21-4.35-4.35"></path>
          </svg>
          <input type="text" class="search-input" placeholder="Search documentation..." autofocus>
          <kbd class="search-kbd">ESC</kbd>
        </div>
        <div class="search-results"></div>
      </div>
    `;
    
    const style = document.createElement('style');
    style.textContent = `
      #custom-search-modal {
        display: none;
        position: fixed;
        inset: 0;
        z-index: 99999;
      }
      #custom-search-modal.open { display: block; }
      #custom-search-modal .search-backdrop {
        position: absolute;
        inset: 0;
        background: rgba(0, 0, 0, 0.5);
        backdrop-filter: blur(4px);
      }
      #custom-search-modal .search-dialog {
        position: absolute;
        top: 15%;
        left: 50%;
        transform: translateX(-50%);
        width: 90%;
        max-width: 600px;
        background: var(--background, #fff);
        border-radius: 12px;
        box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.25);
        overflow: hidden;
        border: 1px solid var(--border, #e4e4e7);
      }
      .dark #custom-search-modal .search-dialog,
      [data-theme="dark"] #custom-search-modal .search-dialog {
        background: #18181b;
        border-color: #27272a;
      }
      #custom-search-modal .search-input-wrapper {
        display: flex;
        align-items: center;
        padding: 16px;
        border-bottom: 1px solid var(--border, #e4e4e7);
        gap: 12px;
      }
      .dark #custom-search-modal .search-input-wrapper,
      [data-theme="dark"] #custom-search-modal .search-input-wrapper {
        border-color: #27272a;
      }
      #custom-search-modal .search-icon {
        color: #71717a;
        flex-shrink: 0;
      }
      #custom-search-modal .search-input {
        flex: 1;
        border: none;
        outline: none;
        font-size: 16px;
        background: transparent;
        color: inherit;
      }
      #custom-search-modal .search-input::placeholder {
        color: #a1a1aa;
      }
      #custom-search-modal .search-kbd {
        background: #f4f4f5;
        padding: 4px 8px;
        border-radius: 4px;
        font-size: 12px;
        color: #71717a;
        font-family: inherit;
      }
      .dark #custom-search-modal .search-kbd,
      [data-theme="dark"] #custom-search-modal .search-kbd {
        background: #27272a;
      }
      #custom-search-modal .search-results {
        max-height: 400px;
        overflow-y: auto;
        padding: 8px;
      }
      #custom-search-modal .search-result {
        display: block;
        padding: 12px 16px;
        border-radius: 8px;
        text-decoration: none;
        color: inherit;
        transition: background 0.15s;
      }
      #custom-search-modal .search-result:hover,
      #custom-search-modal .search-result.selected {
        background: #f4f4f5;
      }
      .dark #custom-search-modal .search-result:hover,
      .dark #custom-search-modal .search-result.selected,
      [data-theme="dark"] #custom-search-modal .search-result:hover,
      [data-theme="dark"] #custom-search-modal .search-result.selected {
        background: #27272a;
      }
      #custom-search-modal .search-result-title {
        font-weight: 600;
        color: #371b53;
        margin-bottom: 4px;
      }
      #custom-search-modal .search-result-description {
        font-size: 14px;
        color: #71717a;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      #custom-search-modal .search-empty {
        padding: 32px;
        text-align: center;
        color: #71717a;
      }
      #custom-search-modal .search-hint {
        padding: 16px;
        text-align: center;
        color: #a1a1aa;
        font-size: 14px;
      }
    `;
    
    document.head.appendChild(style);
    document.body.appendChild(modal);
    
    // Event handlers
    modal.querySelector('.search-backdrop').addEventListener('click', closeModal);
    modal.querySelector('.search-input').addEventListener('input', debounce(handleSearch, 200));
    modal.querySelector('.search-input').addEventListener('keydown', handleKeydown);
    
    return modal;
  }

  function openModal() {
    createModal();
    modal.classList.add('open');
    modal.querySelector('.search-input').value = '';
    modal.querySelector('.search-input').focus();
    modal.querySelector('.search-results').innerHTML = '<div class="search-hint">Type to search...</div>';
    modalOpen = true;
    document.body.style.overflow = 'hidden';
  }

  function closeModal() {
    if (modal) {
      modal.classList.remove('open');
      modalOpen = false;
      document.body.style.overflow = '';
    }
  }

  let selectedIndex = -1;
  let results = [];

  function handleKeydown(e) {
    if (e.key === 'Escape') {
      closeModal();
    } else if (e.key === 'ArrowDown') {
      e.preventDefault();
      selectedIndex = Math.min(selectedIndex + 1, results.length - 1);
      updateSelection();
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      selectedIndex = Math.max(selectedIndex - 1, 0);
      updateSelection();
    } else if (e.key === 'Enter' && results[selectedIndex]) {
      window.location.href = results[selectedIndex].slug;
    }
  }

  function updateSelection() {
    const items = modal.querySelectorAll('.search-result');
    items.forEach((item, i) => {
      item.classList.toggle('selected', i === selectedIndex);
    });
  }

  async function handleSearch(e) {
    const query = e.target.value.trim();
    const resultsContainer = modal.querySelector('.search-results');
    
    if (query.length < 2) {
      resultsContainer.innerHTML = '<div class="search-hint">Type to search...</div>';
      results = [];
      selectedIndex = -1;
      return;
    }

    try {
      const response = await fetch('/api/search', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ q: query, limit: 10 })
      });
      
      if (!response.ok) throw new Error('Search failed');
      
      const data = await response.json();
      results = data.hits || [];
      selectedIndex = results.length > 0 ? 0 : -1;
      
      if (results.length === 0) {
        resultsContainer.innerHTML = '<div class="search-empty">No results found</div>';
      } else {
        resultsContainer.innerHTML = results.map((hit, i) => `
          <a href="${hit.slug}" class="search-result ${i === 0 ? 'selected' : ''}">
            <div class="search-result-title">${escapeHtml(hit.title)}</div>
            ${hit.description ? `<div class="search-result-description">${escapeHtml(hit.description)}</div>` : ''}
          </a>
        `).join('');
      }
    } catch (err) {
      resultsContainer.innerHTML = '<div class="search-empty">Search unavailable</div>';
      console.error('Search error:', err);
    }
  }

  function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
  }

  function debounce(fn, delay) {
    let timer;
    return function(...args) {
      clearTimeout(timer);
      timer = setTimeout(() => fn.apply(this, args), delay);
    };
  }

  // Intercept Cmd+K / Ctrl+K
  document.addEventListener('keydown', function(e) {
    if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
      e.preventDefault();
      e.stopPropagation();
      if (modalOpen) {
        closeModal();
      } else {
        openModal();
      }
    }
    if (e.key === 'Escape' && modalOpen) {
      e.preventDefault();
      closeModal();
    }
  }, true);

  // Override search elements - both input and the clickable search bar
  function overrideSearchInput() {
    // Target search inputs
    const searchInputs = document.querySelectorAll(
      'input[placeholder*="Search"], ' +
      '[role="searchbox"], ' +
      '[aria-label="Search"]'
    );
    
    searchInputs.forEach(input => {
      if (!input.dataset.searchOverridden) {
        input.dataset.searchOverridden = 'true';
        input.addEventListener('click', function(e) {
          e.preventDefault();
          e.stopPropagation();
          openModal();
        }, true);
        input.addEventListener('focus', function(e) {
          e.preventDefault();
          this.blur();
          openModal();
        }, true);
        input.addEventListener('touchend', function(e) {
          e.preventDefault();
          e.stopPropagation();
          openModal();
        }, true);
      }
    });

    // Target Mintlify's search bar container (the clickable div with search icon)
    const searchBars = document.querySelectorAll('[class*="SearchButton"], [class*="search-button"], [class*="SearchBar"]');
    searchBars.forEach(bar => {
      if (!bar.dataset.searchOverridden) {
        bar.dataset.searchOverridden = 'true';
        bar.addEventListener('click', function(e) {
          e.preventDefault();
          e.stopPropagation();
          openModal();
        }, true);
        bar.addEventListener('touchend', function(e) {
          e.preventDefault();
          e.stopPropagation();
          openModal();
        }, true);
      }
    });

    // Target any element with "Search" text (desktop shows ⌘K, mobile may not)
    document.querySelectorAll('button, div[role="button"], [tabindex="0"]').forEach(el => {
      if (el.dataset.searchOverridden) return;
      const text = el.textContent || '';
      // Match "Search" text - mobile may not have keyboard shortcut displayed
      if (text.includes('Search') || text.includes('search')) {
        // Exclude theme toggle and other non-search buttons
        if (text.toLowerCase().includes('theme') || text.toLowerCase().includes('dark') || text.toLowerCase().includes('light')) return;
        el.dataset.searchOverridden = 'true';
        el.addEventListener('click', function(e) {
          e.preventDefault();
          e.stopPropagation();
          openModal();
        }, true);
        el.addEventListener('touchend', function(e) {
          e.preventDefault();
          e.stopPropagation();
          openModal();
        }, true);
      }
    });

    // Target the header search trigger - look for search icon SVG
    document.querySelectorAll('nav button, header button, nav div[tabindex], header div[tabindex], button svg, [role="button"]').forEach(el => {
      if (el.dataset.searchOverridden) return;
      // Check if it looks like a search element (has magnifying glass icon)
      const svg = el.tagName === 'SVG' ? el : el.querySelector('svg');
      if (svg) {
        const svgContent = svg.innerHTML || '';
        // Magnifying glass typically has a circle and a line
        const hasSearchIcon = svgContent.includes('circle') && (svgContent.includes('21 21') || svgContent.includes('line') || svgContent.includes('path'));
        if (hasSearchIcon) {
          const target = el.tagName === 'SVG' ? el.parentElement : el;
          if (target && !target.dataset.searchOverridden) {
            target.dataset.searchOverridden = 'true';
            target.addEventListener('click', function(e) {
              e.preventDefault();
              e.stopPropagation();
              openModal();
            }, true);
            target.addEventListener('touchend', function(e) {
              e.preventDefault();
              e.stopPropagation();
              openModal();
            }, true);
          }
        }
      }
    });

    // Mobile: Target the search bar that shows "Not available on local preview"
    document.querySelectorAll('[class*="not-available"], [class*="NotAvailable"]').forEach(el => {
      if (!el.dataset.searchOverridden) {
        el.dataset.searchOverridden = 'true';
        // Find parent clickable element
        let parent = el.parentElement;
        while (parent && parent !== document.body) {
          if (parent.tagName === 'BUTTON' || parent.getAttribute('role') === 'button' || parent.hasAttribute('tabindex')) {
            if (!parent.dataset.searchOverridden) {
              parent.dataset.searchOverridden = 'true';
              parent.addEventListener('click', function(e) {
                e.preventDefault();
                e.stopPropagation();
                openModal();
              }, true);
              parent.addEventListener('touchend', function(e) {
                e.preventDefault();
                e.stopPropagation();
                openModal();
              }, true);
            }
            break;
          }
          parent = parent.parentElement;
        }
      }
    });
  }

  // Run on load and observe for dynamic elements
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', overrideSearchInput);
  } else {
    overrideSearchInput();
  }
  
  const observer = new MutationObserver(overrideSearchInput);
  observer.observe(document.body, { childList: true, subtree: true });
})();
