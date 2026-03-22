"""HTTP client for forge-api. The bot calls this for ALL project operations."""

import httpx

from config import FORGE_API_URL


class ForgeAPIError(Exception):
    def __init__(self, status_code: int, detail: str):
        self.status_code = status_code
        self.detail = detail
        super().__init__(f"forge-api {status_code}: {detail}")


class ForgeAPIClient:
    def __init__(self):
        self.base = FORGE_API_URL

    async def _request(self, method: str, path: str, **kwargs) -> dict:
        async with httpx.AsyncClient(base_url=self.base, timeout=300) as client:
            resp = await client.request(method, path, **kwargs)
            if resp.status_code >= 400:
                detail = resp.text[:500]
                raise ForgeAPIError(resp.status_code, detail)
            return resp.json()

    async def health(self) -> dict:
        return await self._request("GET", "/health")

    async def list_projects(self) -> dict:
        return await self._request("GET", "/projects")

    async def project_status(self, name: str) -> dict:
        return await self._request("GET", f"/projects/{name}/status")

    async def deploy(self, name: str, environment: str, pr_number: int | None = None) -> dict:
        body = {"environment": environment}
        if pr_number is not None:
            body["pr_number"] = pr_number
        return await self._request("POST", f"/projects/{name}/deploy", json=body)

    async def run(self, name: str) -> dict:
        return await self._request("POST", f"/projects/{name}/run")

    async def plan(self, name: str) -> dict:
        return await self._request("POST", f"/projects/{name}/plan")

    async def adopt(self, path: str, name: str | None = None, stack: str | None = None) -> dict:
        body = {"path": path, "skip_analyze": True}
        if name:
            body["name"] = name
        if stack:
            body["stack"] = stack
        return await self._request("POST", "/projects/adopt", json=body)

    async def create_project(self, name: str, stack: str) -> dict:
        return await self._request("POST", "/projects/new", json={"name": name, "stack": stack})

    async def add_feature(self, name: str, title: str, description: str, priority: int = 2) -> dict:
        return await self._request(
            "POST",
            f"/projects/{name}/feature",
            json={"title": title, "description": description, "priority": priority},
        )

    async def promote(self, name: str, target_stage: str) -> dict:
        return await self._request("POST", f"/projects/{name}/promote", json={"target_stage": target_stage})

    async def staging_report(self, name: str) -> dict:
        return await self._request("GET", f"/projects/{name}/staging-report")

    async def trigger_e2e(self, name: str) -> dict:
        return await self._request("POST", f"/projects/{name}/e2e")

    async def notify(self, name: str) -> dict:
        return await self._request("POST", f"/projects/{name}/notify")


api = ForgeAPIClient()
