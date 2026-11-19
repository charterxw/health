"""Check the protected workout report and its public rendering contract."""
import os
import httpx

with httpx.Client(base_url="http://127.0.0.1:8000", timeout=20) as client:
    assert client.get("/api/insights/training").status_code == 401
    login = client.post("/api/auth/app-login", json={
        "username": os.environ["DASHBOARD_USER"], "password": os.environ["DASHBOARD_PASS"],
    })
    login.raise_for_status()
    cookie = login.cookies.get("dashboard_session")
    headers = {"Cookie": f"dashboard_session={cookie}"}
    response = client.get("/api/insights/training", headers=headers)
    response.raise_for_status()
    result = response.json()
    report = result["report"]
    assert report["version"] == "training-observations-v1"
    assert len(report["findings"]) <= 2
    assert len(result["summary"]) <= 300
    assert "input_json" not in result and "input_hash" not in result
    print("Workout report:", report["session_date"], "findings=", len(report["findings"]),
          "visible_characters=", len(result["summary"]))
    for endpoint in ("sleep", "weekly"):
        response = client.get(f"/api/insights/{endpoint}", headers=headers)
        response.raise_for_status()
        assert response.json()["report"]["version"] == "observations-v1"
        print(endpoint, "still available")
    # Verify that the reverse proxy serves the same authenticated report.
    response = client.get("http://frontend/api/insights/training", headers=headers)
    response.raise_for_status()
    assert response.json()["summary"] == result["summary"]
    print("Authenticated frontend proxy check passed")
