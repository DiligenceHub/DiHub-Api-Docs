# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development

```bash
npm run dev    # start local preview at http://localhost:3000
```

If the dev server isn't running, update the CLI first: `mint update`

Deployment is automatic — pushing to `main` triggers a production deploy via the Mintlify GitHub app.

## Architecture

Config lives in `docs.json` (navigation, theme, colors, navbar). Content pages are `.mdx` files using Mintlify components.

The OpenAPI spec at `openapi.json` (root) drives the API Reference tab automatically — no manual MDX needed for endpoints.

**Adding a page:** create the `.mdx` file, then register it under the appropriate `groups.pages` array in `docs.json`.

## Project constants

- Language: **Portuguese (pt-BR)**
- Primary color: `#6d27d9` (purple)
- API auth header: `X-Api-Token`
- API base URL: `https://api.dihub.com.br/v1`

---

# Mintlify documentation

## Working relationship
- You can push back on ideas-this can lead to better documentation. Cite sources and explain your reasoning when you do so
- ALWAYS ask for clarification rather than making assumptions
- NEVER lie, guess, or make up anything

## Project context
- Format: MDX files with YAML frontmatter
- Config: docs.json for navigation, theme, settings
- Components: Mintlify components

## Content strategy
- Document just enough for user success - not too much, not too little
- Prioritize accuracy and usability
- Make content evergreen when possible
- Search for existing content before adding anything new. Avoid duplication unless it is done for a strategic reason
- Check existing patterns for consistency
- Start by making the smallest reasonable changes

## docs.json

- Refer to the [docs.json schema](https://mintlify.com/docs.json) when building the docs.json file and site navigation

## Frontmatter requirements for pages
- title: Clear, descriptive page title
- description: Concise summary for SEO/navigation

## Writing standards
- Second-person voice ("you")
- Prerequisites at start of procedural content
- Test all code examples before publishing
- Match style and formatting of existing pages
- Include both basic and advanced use cases
- Language tags on all code blocks
- Alt text on all images
- Relative paths for internal links

## Git workflow
- NEVER use --no-verify when committing
- Ask how to handle uncommitted changes before starting
- Create a new branch when no clear branch exists for changes
- Commit frequently throughout development
- NEVER skip or disable pre-commit hooks

## Do not
- Skip frontmatter on any MDX file
- Use absolute URLs for internal links
- Include untested code examples
- Make assumptions - always ask for clarification