require("dotenv").config();

const { poll } = require("./consumer");

const required = ["AWS_REGION"];
const missing = required.filter((key) => !process.env[key]);

if (missing.length > 0) {
  console.error("Missing required environment variables:", missing.join(", "));
  process.exit(1);
}

if (!process.env.SQS_ORDERS_QUEUE_URL && !process.env.SQS_CART_QUEUE_URL) {
  console.error("At least one queue URL must be set: SQS_ORDERS_QUEUE_URL or SQS_CART_QUEUE_URL");
  process.exit(1);
}

poll().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
