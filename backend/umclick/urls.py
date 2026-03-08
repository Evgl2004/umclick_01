from django.contrib import admin
from django.urls import include, path

urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/quizzes/", include("apps.quiz.urls")),
    path("api/sessions/", include("apps.session.urls")),
]
