# GPSL site map

The canonical, up-to-date site map is the admin page:

**[admin_site_map.html](admin_site_map.html)** — open in the browser as **Admin → Testing → Site map**

That page lists all owner and admin pages, grouped by area (squad, finances, transfers, season admin, etc.).

## Maintenance

When you add or reorganise pages or navigation, update **`admin_site_map.html`** in the same change.

Sources of truth for nav structure:

- `nav_config.js` — owner top nav + admin mega-menu entries
- `dashboard_registry.js` — dashboard pin targets
- `admin_main_nav.js`, `admin_testing_nav.js` — Admin mega-menus + checklist; season sidebars reuse `admin_main_nav`

Cursor agents are reminded via `.cursor/rules/site-map-maintenance.mdc`.
