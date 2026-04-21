const {
  SQSClient,
  ReceiveMessageCommand,
  DeleteMessageCommand,
} = require("@aws-sdk/client-sqs");

const client = new SQSClient({ region: process.env.AWS_REGION });

const QUEUES = {
  order: process.env.SQS_ORDERS_QUEUE_URL,
  cart: process.env.SQS_CART_QUEUE_URL,
};

async function receiveMessages(queueUrl) {
  const response = await client.send(
    new ReceiveMessageCommand({
      QueueUrl: queueUrl,
      MaxNumberOfMessages: 10,
      WaitTimeSeconds: 20, // long polling
      AttributeNames: ["All"],
      MessageAttributeNames: ["All"],
    })
  );

  return response.Messages ?? [];
}

async function deleteMessage(queueUrl, receiptHandle) {
  await client.send(
    new DeleteMessageCommand({
      QueueUrl: queueUrl,
      ReceiptHandle: receiptHandle,
    })
  );
}

async function processMessage(message, queueType) {
  let event;

  try {
    console.log(`Received message ${message.MessageId} with body:`, message.Body);
    event = JSON.parse(message.Body);
  } catch {
    console.error("Failed to parse message body:", message.Body);
    return;
  }

  const detail = event.detail ?? {};
  const resourceId = detail.resource?.id ?? "unknown";
  const messageType = detail.type ?? "unknown";
  const projectKey = detail.projectKey ?? "unknown";

  console.log(`[${new Date().toISOString()}] ${messageType} | ${queueType}: ${resourceId} | project: ${projectKey}`);

  // TODO: add your business logic here
  // e.g. forward to another service, update a database, trigger a workflow
}

async function pollQueue(queueType, queueUrl) {
  console.log(`Polling ${queueType} queue: ${queueUrl} ...`);

  while (true) {
    let messages;

    try {
      messages = await receiveMessages(queueUrl);
    } catch (err) {
      console.error(`[${queueType}] Error receiving messages:`, err.message);
      await sleep(5000);
      continue;
    }

    if (messages.length === 0) {
      continue; // long poll returned empty, loop immediately
    }

    for (const message of messages) {
      try {
        await processMessage(message, queueType);
        await deleteMessage(queueUrl, message.ReceiptHandle);
      } catch (err) {
        console.error(`[${queueType}] Error processing message ${message.MessageId}:`, err.message);
        // message will become visible again after visibility timeout
      }
    }
  }
}

async function poll() {
  const activeQueues = Object.entries(QUEUES).filter(([, url]) => url);

  if (activeQueues.length === 0) {
    throw new Error("No queue URLs configured. Set SQS_ORDERS_QUEUE_URL and/or SQS_CART_QUEUE_URL.");
  }

  await Promise.all(activeQueues.map(([queueType, queueUrl]) => pollQueue(queueType, queueUrl)));
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

module.exports = { poll };
