const fs = require('fs');
const path = '/evolution/node_modules/baileys/lib/Utils/messages-media.js';
let code = fs.readFileSync(path, 'utf8');

if (code.includes('could not generate document thumb')) {
    process.exit(0); // already patched
}

const MARKER = "options.logger?.debug('could not generate video thumb: ' + err);\n        }\n    }\n    return {";

if (!code.includes(MARKER)) {
    console.error('[patch-baileys] marker not found, skipping');
    process.exit(0);
}

const PDF_BLOCK = `options.logger?.debug('could not generate video thumb: ' + err);
        }
    }
    else if (mediaType === 'document') {
        const outPrefix = join(getTmpFilesDirectory(), generateMessageIDV2());
        try {
            await new Promise((resolve, reject) => {
                const cmd = 'pdftoppm -f 1 -l 1 -r 72 -jpeg -singlefile "' + file + '" "' + outPrefix + '"';
                exec(cmd, (err) => { if (err) reject(err); else resolve(); });
            });
            const outFile = outPrefix + '.jpg';
            const pageBuffer = await fs.readFile(outFile);
            const lib = await getImageProcessingLibrary();
            const thumbBuffer = 'sharp' in lib && typeof lib.sharp?.default === 'function'
                ? await lib.sharp.default(pageBuffer).resize(100).jpeg({ quality: 50 }).toBuffer()
                : pageBuffer;
            thumbnail = thumbBuffer.toString('base64');
            await fs.unlink(outFile);
        }
        catch (err) {
            options.logger?.debug('could not generate document thumb: ' + err);
        }
    }
    return {`;

const patched = code.replace(MARKER, PDF_BLOCK);
fs.writeFileSync(path, patched);
console.log('[patch-baileys] PDF thumbnail patch applied to Baileys messages-media.js');
