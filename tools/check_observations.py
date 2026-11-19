"""Check the live protected endpoints without printing credentials."""
import os
import httpx

with httpx.Client(base_url="http://127.0.0.1:8000", timeout=15) as client:
    assert client.get("/api/insights/weekly").status_code == 401
    login = client.post("/api/auth/app-login", json={
        "username": os.environ["DASHBOARD_USER"], "password": os.environ["DASHBOARD_PASS"],
    })
    login.raise_for_status()
    # The normal production cookie is HTTPS-only; this check talks over container loopback.
    cookie = login.cookies.get("dashboard_session")
    for endpoint in ("sleep", "weekly", "today", "history?days=7"):
        response = client.get(f"/api/insights/{endpoint}", headers={"Cookie": f"dashboard_session={cookie}"})
        response.raise_for_status()
        data = response.json()
        if isinstance(data, dict):
            assert data["report"]["version"] == "observations-v1"
            assert "input_json" not in data
            print(endpoint, data["report"]["status"], "visible_characters=", len(data["content"]))
        else:
            assert all("input_json" not in row for row in data)
            print(endpoint, "ok", len(data), "records")
print("Authenticated read checks passed; weekly endpoint requires a session")
