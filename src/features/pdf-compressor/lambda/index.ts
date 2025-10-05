export const handler = async (event: any, context: any) => {
    console.log("Event:", JSON.stringify(event, null, 2));
    console.log("Context:", JSON.stringify(context, null, 2));

    return {
        statusCode: 200,
        headers: {
            'Content-Type': 'application/json',
        },
        body: JSON.stringify({
            message: "Hello from lambda",
            requestId: context.awsRequestId
        })
    };
};