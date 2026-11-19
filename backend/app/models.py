from pydantic import BaseModel
from typing import Optional


class HealthMetric(BaseModel):
    id: Optional[int] = None
    date: str
    steps: int = 0
    sleep_hours: float = 0
    sleep_quality: str = "unknown"
    hrv: int = 0
    resting_hr: int = 0
    calories_burned: int = 0
    active_minutes: int = 0


class Workout(BaseModel):
    id: Optional[int] = None
    date: str
    type: str
    duration_minutes: int
    intensity: str
    calories_burned: int = 0
    notes: Optional[str] = None


class AIInsight(BaseModel):
    id: Optional[int] = None
    date: str
    time_slot: str
    title: str
    content: str
    category: str = "general"


class TrainingAnalysis(BaseModel):
    id: Optional[int] = None
    date: str
    summary: str
    trends: Optional[str] = None
    risks: Optional[str] = None
    recommendations: Optional[str] = None
