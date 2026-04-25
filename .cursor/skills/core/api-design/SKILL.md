---
name: api-design
description: "REST/GraphQL API design patterns, contract-first development, and OpenAPI spec writing. Use when designing new endpoints, defining request/response schemas, writing API contracts, versioning APIs, or reviewing API design. Trigger on 'endpoint', 'API', 'REST', 'GraphQL', 'schema', 'contract', 'OpenAPI'."
triggers: ["api", "endpoint", "REST", "GraphQL", "schema", "contract", "OpenAPI", "swagger"]
when-to-use: "Step 2 (System Design) API contract phase, Step 4 (Backend Dev) endpoint implementation, any API review."
when-not-to-use: "Do not use for frontend UI design, database schema design (use database-design skill), or infrastructure."
prerequisites: []
estimated-tokens: 1400
roles-suggested: ["backend", "tech-lead"]
version: "1.0.0"
tags: ["api", "backend", "design"]
---
# Skill: API Design | Backend / Tech Lead | Steps 2, 4

## 1. Contract-First Principle
Viết API contract (OpenAPI spec) TRƯỚC khi code. Frontend và Backend có thể làm song song nhờ mock server từ spec.

```yaml
# OpenAPI 3.0 skeleton
openapi: 3.0.3
info:
  title: [Service Name] API
  version: 1.0.0
paths:
  /resource:
    get:
      summary: List resources
      parameters: [...]
      responses:
        '200':
          description: Success
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/ResourceList'
        '400': { $ref: '#/components/responses/BadRequest' }
        '401': { $ref: '#/components/responses/Unauthorized' }
```

## 2. REST Design Rules

### URL Conventions
```
GET    /users           # list
POST   /users           # create
GET    /users/{id}      # read
PUT    /users/{id}      # replace
PATCH  /users/{id}      # partial update
DELETE /users/{id}      # delete

# Nested resources (max 2 levels)
GET /users/{id}/orders
GET /orders/{id}/items

# Actions (khi CRUD không đủ)
POST /users/{id}/activate
POST /payments/{id}/refund
```

### Response Format chuẩn
```json
// Success list
{ "data": [...], "meta": { "total": 100, "page": 1, "per_page": 20 } }

// Success single
{ "data": { "id": "...", ... } }

// Error
{ "error": { "code": "VALIDATION_ERROR", "message": "...", "details": [...] } }
```

### HTTP Status Codes
| Code | Khi dùng |
|------|----------|
| 200 | OK (GET, PUT, PATCH) |
| 201 | Created (POST) |
| 204 | No Content (DELETE) |
| 400 | Bad Request (validation fail) |
| 401 | Unauthorized (no/invalid token) |
| 403 | Forbidden (valid token, no permission) |
| 404 | Not Found |
| 409 | Conflict (duplicate) |
| 422 | Unprocessable Entity (business logic fail) |
| 429 | Too Many Requests |
| 500 | Internal Server Error |

## 3. API Versioning
- URL versioning: `/v1/users` (khuyến nghị cho public APIs)
- Header versioning: `Accept: application/vnd.api+json;version=1` (internal)
- Không breaking change trong cùng major version

## 4. Security Checklist
- [ ] Authentication required (JWT / API key) trừ public endpoints
- [ ] Rate limiting defined per endpoint
- [ ] Input validation trên tất cả request body/params
- [ ] Sensitive data KHÔNG xuất hiện trong URL params
- [ ] CORS policy defined
- [ ] API keys không log trong plain text
