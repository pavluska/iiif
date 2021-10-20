const http = require('http');
const https = require('https');
const app = require('./app');
const server = http.createServer(app);

// PORT
const port = process.env.PORT || 3000;
server.listen(port, () => console.log(`Listening on port ${port}`));
app.set('port', port);