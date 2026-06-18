const nodemailer = require('nodemailer');
require('dotenv').config();

const t = nodemailer.createTransport({
  host: process.env.TITAN_SMTP_HOST || 'smtp.titan.email',
  port: 465,
  secure: true,
  auth: { user: process.env.TITAN_EMAIL, pass: process.env.TITAN_PASSWORD },
  debug: true,
  logger: true,
});

console.log('--- Verifying transporter ---');
console.log('User:', process.env.TITAN_EMAIL);
console.log('Host:', process.env.TITAN_SMTP_HOST);

t.verify().then(() => {
  console.log('--- SMTP verified OK, sending test ---');
  return t.sendMail({
    from: process.env.TITAN_EMAIL,
    to: 'dylanlesieur@outlook.fr',
    subject: 'Test Vite Gourmand ' + new Date().toLocaleTimeString(),
    text: 'This is a plain text test email from Titan SMTP. If you receive this, the SMTP works.',
  });
}).then(info => {
  console.log('--- SENT ---');
  console.log('Response:', info.response);
  console.log('MessageId:', info.messageId);
  console.log('Accepted:', info.accepted);
  console.log('Rejected:', info.rejected);
  console.log('Envelope:', JSON.stringify(info.envelope));
}).catch(err => {
  console.error('--- ERROR ---');
  console.error(err);
});
