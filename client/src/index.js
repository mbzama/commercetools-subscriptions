require("dotenv").config();

const { poll } = require("./consumer");

const required = ["AWS_REGION", "SQS_QUEUE_URL"];
const missing = required.filter((key) => !process.env[key]);

if (missing.length > 0) {
  console.error("Missing required environment variables:", missing.join(", "));
  process.exit(1);
}

poll().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
