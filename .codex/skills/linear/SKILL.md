---
name: linear
description: |
  Use Symphony's `linear_graphql` client tool for raw Linear GraphQL
  operations such as comment editing and upload flows.
---

# Linear GraphQL

Use this skill for raw Linear GraphQL work during Symphony app-server sessions.

## Primary tool

Use the `linear_graphql` client tool exposed by Symphony's app-server session.
It reuses Symphony's configured Linear auth for the session.

Tool input:

```json
{
  "query": "query or mutation document",
  "variables": {
    "optional": "graphql variables object"
  }
}
```

Tool behavior:

- Send one GraphQL operation per tool call.
- Treat a top-level `errors` array as a failed GraphQL operation even if the
  tool call itself completed.
- Keep queries/mutations narrowly scoped; ask only for the fields you need.
- Do not guess removed fields back into queries. The current `Issue` link
  surfaces are `attachments` for attached URLs/PRs and `relations` /
  `inverseRelations` for issue-to-issue relationships.
- GraphQL object `id` fields may be returned as `ID`, while many Linear mutation
  arguments and input fields are declared as `String`. Match the variable type
  to the operation or input object you introspected.

## Discovering unfamiliar operations

When you need an unfamiliar mutation, input type, or object field, use targeted
introspection through `linear_graphql`.

List mutation names:

```graphql
query ListMutations {
  __type(name: "Mutation") {
    fields {
      name
    }
  }
}
```

Inspect a specific input object:

```graphql
query CommentCreateInputShape {
  __type(name: "CommentCreateInput") {
    inputFields {
      name
      type {
        kind
        name
        ofType {
          kind
          name
        }
      }
    }
  }
}
```

## Common workflows

### Query an issue by key, identifier, or id

Use these progressively:

- Start with `issue(id: $key)` when you have a ticket key such as `MT-686`.
- Fall back to `issues(filter: ...)` when you need identifier search semantics.
- Once you have the internal issue id, prefer `issue(id: $id)` for narrower reads.

Lookup by issue key:

```graphql
query IssueByKey($key: String!) {
  issue(id: $key) {
    id
    identifier
    title
    state {
      id
      name
      type
    }
    project {
      id
      name
    }
    branchName
    url
    description
    updatedAt
    attachments {
      nodes {
        id
        title
        url
        sourceType
      }
    }
  }
}
```

Lookup by identifier filter:

```graphql
query IssueByIdentifier($identifier: String!) {
  issues(filter: { identifier: { eq: $identifier } }, first: 1) {
    nodes {
      id
      identifier
      title
      state {
        id
        name
        type
      }
      project {
        id
        name
      }
      branchName
      url
      description
      updatedAt
    }
  }
}
```

Resolve a key to an internal id:

```graphql
query IssueByIdOrKey($id: String!) {
  issue(id: $id) {
    id
    identifier
    title
  }
}
```

Read the issue once the internal id is known:

```graphql
query IssueDetails($id: String!) {
  issue(id: $id) {
    id
    identifier
    title
    url
    description
    state {
      id
      name
      type
    }
    project {
      id
      name
    }
    attachments {
      nodes {
        id
        title
        url
        sourceType
      }
    }
  }
}
```

### Discover PR links and issue relations

Use `attachments` for attached PRs and URL links. Use `relations` and
`inverseRelations` only for issue-to-issue relationships. Do not query
`Issue.links`; it is not present in the current schema.

```graphql
query IssueAttachmentsAndRelations(
  $id: String!
  $attachmentFirst: Int!
  $relationFirst: Int!
) {
  issue(id: $id) {
    id
    identifier
    attachments(first: $attachmentFirst) {
      nodes {
        id
        title
        url
        sourceType
      }
    }
    relations(first: $relationFirst) {
      nodes {
        id
        type
        relatedIssue {
          id
          identifier
          title
          url
        }
      }
    }
    inverseRelations(first: $relationFirst) {
      nodes {
        id
        type
        issue {
          id
          identifier
          title
          url
        }
      }
    }
  }
}
```

If a link or relation path is unclear, introspect the exact types before writing
the query:

```graphql
query IssueLinkFieldDiscovery {
  issue: __type(name: "Issue") {
    fields {
      name
      args {
        name
        type {
          kind
          name
          ofType {
            kind
            name
            ofType {
              kind
              name
            }
          }
        }
      }
      type {
        kind
        name
        ofType {
          kind
          name
          ofType {
            kind
            name
          }
        }
      }
    }
  }
  attachment: __type(name: "Attachment") {
    fields {
      name
      type {
        kind
        name
        ofType {
          kind
          name
          ofType {
            kind
            name
          }
        }
      }
    }
  }
  relation: __type(name: "IssueRelation") {
    fields {
      name
      type {
        kind
        name
        ofType {
          kind
          name
          ofType {
            kind
            name
          }
        }
      }
    }
  }
  relationInput: __type(name: "IssueRelationCreateInput") {
    inputFields {
      name
      type {
        kind
        name
        ofType {
          kind
          name
          ofType {
            kind
            name
          }
        }
      }
    }
  }
  relationTypes: __type(name: "IssueRelationType") {
    enumValues {
      name
    }
  }
}
```

### Query team workflow states for an issue

Use this before changing issue state when you need the exact `stateId`:

```graphql
query IssueTeamStates($id: String!) {
  issue(id: $id) {
    id
    team {
      id
      key
      name
      states {
        nodes {
          id
          name
          type
        }
      }
    }
  }
}
```

### Edit an existing comment

Use `commentUpdate` through `linear_graphql`:

```graphql
mutation UpdateComment($id: String!, $body: String!) {
  commentUpdate(id: $id, input: { body: $body }) {
    success
    comment {
      id
      body
    }
  }
}
```

### Create a comment

Use `commentCreate` through `linear_graphql`:

```graphql
mutation CreateComment($issueId: String!, $body: String!) {
  commentCreate(input: { issueId: $issueId, body: $body }) {
    success
    comment {
      id
      url
    }
  }
}
```

### Move an issue to a different state

Use `issueUpdate` with the destination `stateId`. In the current schema, both
the top-level mutation `id` argument and the `stateId` input field are `String`
values:

```graphql
mutation MoveIssueToState($id: String!, $stateId: String!) {
  issueUpdate(id: $id, input: { stateId: $stateId }) {
    success
    issue {
      id
      identifier
      state {
        id
        name
      }
    }
  }
}
```

### Create an issue in a project

Use the exact scalar types from `IssueCreateInput`: `teamId` is `String!`, while
`projectId` and `stateId` are nullable `String` fields. Do not declare these as
`ID` unless current introspection says the field changed.

```graphql
mutation CreateIssueInProject(
  $teamId: String!
  $title: String!
  $description: String
  $projectId: String
  $stateId: String
) {
  issueCreate(
    input: {
      teamId: $teamId
      title: $title
      description: $description
      projectId: $projectId
      stateId: $stateId
    }
  ) {
    success
    issue {
      id
      identifier
      url
      project {
        id
        name
      }
      state {
        id
        name
      }
    }
  }
}
```

### Create an issue relation

Use `String!` for `issueId` and `relatedIssueId`, and use the
`IssueRelationType!` enum for the relation type. Current enum values are
`blocks`, `duplicate`, `related`, and `similar`.

```graphql
mutation CreateIssueRelation(
  $issueId: String!
  $relatedIssueId: String!
  $type: IssueRelationType!
) {
  issueRelationCreate(
    input: {
      issueId: $issueId
      relatedIssueId: $relatedIssueId
      type: $type
    }
  ) {
    success
    issueRelation {
      id
      type
      issue {
        id
        identifier
      }
      relatedIssue {
        id
        identifier
      }
    }
  }
}
```

### Attach a GitHub PR to an issue

Use the GitHub-specific attachment mutation when linking a PR:

```graphql
mutation AttachGitHubPR($issueId: String!, $url: String!, $title: String) {
  attachmentLinkGitHubPR(
    issueId: $issueId
    url: $url
    title: $title
    linkKind: links
  ) {
    success
    attachment {
      id
      title
      url
    }
  }
}
```

If you only need a plain URL attachment and do not care about GitHub-specific
link metadata, use:

```graphql
mutation AttachURL($issueId: String!, $url: String!, $title: String) {
  attachmentLinkURL(issueId: $issueId, url: $url, title: $title) {
    success
    attachment {
      id
      title
      url
    }
  }
}
```

### Introspection patterns used during schema discovery

Use these when the exact field or mutation shape is unclear:

```graphql
query QueryFields {
  __type(name: "Query") {
    fields {
      name
    }
  }
}
```

```graphql
query IssueFieldArgs {
  __type(name: "Query") {
    fields {
      name
      args {
        name
        type {
          kind
          name
          ofType {
            kind
            name
            ofType {
              kind
              name
            }
          }
        }
      }
    }
  }
}
```

### Upload a video to a comment

Do this in three steps:

1. Call `linear_graphql` with `fileUpload` to get `uploadUrl`, `assetUrl`, and
   any required upload headers.
2. Upload the local file bytes to `uploadUrl` with `curl -X PUT` and the exact
   headers returned by `fileUpload`.
3. Call `linear_graphql` again with `commentCreate` (or `commentUpdate`) and
   include the resulting `assetUrl` in the comment body.

Useful mutations:

```graphql
mutation FileUpload(
  $filename: String!
  $contentType: String!
  $size: Int!
  $makePublic: Boolean
) {
  fileUpload(
    filename: $filename
    contentType: $contentType
    size: $size
    makePublic: $makePublic
  ) {
    success
    uploadFile {
      uploadUrl
      assetUrl
      headers {
        key
        value
      }
    }
  }
}
```

## Usage rules

- Use `linear_graphql` for comment edits, uploads, and ad-hoc Linear API
  queries.
- Prefer the narrowest issue lookup that matches what you already know:
  key -> identifier search -> internal id.
- For state transitions, fetch team states first and use the exact `stateId`
  instead of hardcoding names inside mutations.
- For issue/project/state/comment/relation mutation variables, mirror the
  introspected schema. In the current Linear schema, `issueId`,
  `relatedIssueId`, `projectId`, `stateId`, and mutation `id` arguments shown
  above are `String` / `String!`, not `ID` / `ID!`.
- For PR or URL discovery, query `attachments`; for issue-to-issue dependency or
  related-ticket discovery, query `relations` / `inverseRelations`.
- Prefer `attachmentLinkGitHubPR` over a generic URL attachment when linking a
  GitHub PR to a Linear issue.
- Do not introduce new raw-token shell helpers for GraphQL access.
- If you need shell work for uploads, only use it for signed upload URLs
  returned by `fileUpload`; those URLs already carry the needed authorization.
