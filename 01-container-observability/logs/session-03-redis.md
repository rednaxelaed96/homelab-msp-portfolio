# Step 1: Setup App Insights and Monitor on Lab-Api
I started this step by creating a new application insight resource called "appins-labapi-homelab" and set it to send logs to the workspace we created in session 2, "law-homelab". From monitor, I also created a diagnostic setting on the lab-api app called "LabapiMetricsToMonitor" that sends AllMetrics to "law-homelab". Then, we need to add the requirements to the app.

