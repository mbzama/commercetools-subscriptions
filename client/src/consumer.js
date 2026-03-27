const {
  SQSClient,
  ReceiveMessageCommand,
  DeleteMessageCommand,
} = require("@aws-sdk/client-sqs");

const client = new SQSClient({ region: process.env.AWS_REGION });
const QUEUE_URL = process.env.SQS_QUEUE_URL;

async function receiveMessages() {
  const response = await client.send(
    new ReceiveMessageCommand({
      QueueUrl: QUEUE_URL,
      MaxNumberOfMessages: 10,
      WaitTimeSeconds: 20, // long polling
      AttributeNames: ["All"],
      MessageAttributeNames: ["All"],
    })
  );

  return response.Messages ?? [];
}

async function deleteMessage(receiptHandle) {
  await client.send(
    new DeleteMessageCommand({
      QueueUrl: QUEUE_URL,
      ReceiptHandle: receiptHandle,
    })
  );
}

async function processMessage(message) {
  let event;

  try {
    console.log(`Received message ${message.MessageId} with body:`, message.Body);
    event = JSON.parse(message.Body);
  } catch {
    console.error("Failed to parse message body:", message.Body);
    return;
  }

  const detail = event.detail ?? {};
  const orderId = detail.resource?.id ?? "unknown";
  const messageType = detail.type ?? "unknown";
  const projectKey = detail.projectKey ?? "unknown";

  console.log(`[${new Date().toISOString()}] ${messageType} | order: ${orderId} | project: ${projectKey}`);

  // TODO: add your business logic here
  // e.g. forward to another service, update a database, trigger a workflow
}

async function poll() {
  console.log(`Polling ${QUEUE_URL} ...`);

  while (true) {
    let messages;

    try {
      messages = await receiveMessages();
    } catch (err) {
      console.error("Error receiving messages:", err.message);
      await sleep(5000);
      continue;
    }

    if (messages.length === 0) {
      continue; // long poll returned empty, loop immediately
    }

    for (const message of messages) {
      try {
        await processMessage(message);
        await deleteMessage(message.ReceiptHandle);
      } catch (err) {
        console.error(`Error processing message ${message.MessageId}:`, err.message);
        // message will become visible again after visibility timeout
      }
    }
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

module.exports = { poll };
