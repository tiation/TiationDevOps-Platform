import winston from 'winston';
import 'winston-mongodb';
import path from 'path';

const { combine, timestamp, errors, printf, colorize, json } = winston.format;

// Custom format for console output
const consoleFormat = printf(({ level, message, timestamp, stack, ...meta }) => {
  let log = `${timestamp} [${level}]: ${message}`;
  
  if (stack) {
    log += `\n${stack}`;
  }
  
  if (Object.keys(meta).length > 0) {
    log += `\n${JSON.stringify(meta, null, 2)}`;
  }
  
  return log;
});

// Custom format for file output
const fileFormat = combine(
  timestamp({ format: 'YYYY-MM-DD HH:mm:ss' }),
  errors({ stack: true }),
  json()
);

// Log levels
const levels = {
  error: 0,
  warn: 1,
  info: 2,
  http: 3,
  debug: 4,
};

const colors = {
  error: 'red',
  warn: 'yellow',
  info: 'green',
  http: 'magenta',
  debug: 'white',
};

winston.addColors(colors);

// Create logs directory if it doesn't exist
const logsDir = path.join(process.cwd(), 'logs');

const transports: winston.transport[] = [
  // Console transport
  new winston.transports.Console({
    level: process.env.NODE_ENV === 'production' ? 'info' : 'debug',
    format: combine(
      colorize({ all: true }),
      timestamp({ format: 'YYYY-MM-DD HH:mm:ss' }),
      errors({ stack: true }),
      consoleFormat
    ),
  }),
  
  // File transport for all logs
  new winston.transports.File({
    filename: path.join(logsDir, 'app.log'),
    level: 'info',
    format: fileFormat,
    maxsize: 20 * 1024 * 1024, // 20MB
    maxFiles: 14, // Keep 14 days of logs
    tailable: true,
  }),
  
  // File transport for error logs
  new winston.transports.File({
    filename: path.join(logsDir, 'error.log'),
    level: 'error',
    format: fileFormat,
    maxsize: 20 * 1024 * 1024, // 20MB
    maxFiles: 30, // Keep 30 days of error logs
    tailable: true,
  }),
];

// Add MongoDB transport in production
if (process.env.NODE_ENV === 'production' && process.env.MONGODB_URI) {
  transports.push(
    new winston.transports.MongoDB({
      db: process.env.MONGODB_URI,
      collection: 'logs',
      level: 'error',
      options: {
        useUnifiedTopology: true,
      },
      format: combine(
        timestamp(),
        errors({ stack: true }),
        json()
      ),
    })
  );
}

// Create logger instance
export const logger = winston.createLogger({
  levels,
  level: process.env.LOG_LEVEL || 'info',
  format: combine(
    timestamp({ format: 'YYYY-MM-DD HH:mm:ss' }),
    errors({ stack: true })
  ),
  transports,
  exitOnError: false,
});

// Handle uncaught exceptions and unhandled rejections
logger.exceptions.handle(
  new winston.transports.File({
    filename: path.join(logsDir, 'exceptions.log'),
    format: fileFormat,
  })
);

logger.rejections.handle(
  new winston.transports.File({
    filename: path.join(logsDir, 'rejections.log'),
    format: fileFormat,
  })
);

// Create a stream object for Morgan HTTP request logger
export const logStream = {
  write: (message: string) => {
    // Remove trailing newline
    logger.http(message.trim());
  },
};

// Utility functions for structured logging
export const logWithContext = (level: string, message: string, context: object = {}) => {
  logger.log(level, message, context);
};

export const logError = (error: Error, context: object = {}) => {
  logger.error(error.message, {
    stack: error.stack,
    name: error.name,
    ...context,
  });
};

export const logInfo = (message: string, context: object = {}) => {
  logger.info(message, context);
};

export const logWarn = (message: string, context: object = {}) => {
  logger.warn(message, context);
};

export const logDebug = (message: string, context: object = {}) => {
  logger.debug(message, context);
};

// Performance logging
export const logPerformance = (operation: string, duration: number, context: object = {}) => {
  logger.info(`Performance: ${operation}`, {
    duration: `${duration}ms`,
    operation,
    ...context,
  });
};

// Security logging
export const logSecurity = (event: string, details: object = {}) => {
  logger.warn(`Security Event: ${event}`, {
    type: 'security',
    event,
    timestamp: new Date().toISOString(),
    ...details,
  });
};

// Audit logging
export const logAudit = (action: string, userId: string, details: object = {}) => {
  logger.info(`Audit: ${action}`, {
    type: 'audit',
    action,
    userId,
    timestamp: new Date().toISOString(),
    ...details,
  });
};

export default logger;
