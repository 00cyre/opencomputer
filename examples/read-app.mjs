import {createComputer} from '../src/computer.mjs';
const bundleId=process.argv[2];
if(!bundleId)throw Error('Usage: node examples/read-app.mjs com.apple.TextEdit');
const computer=createComputer({apps:[bundleId]});
try {console.log(JSON.stringify(await computer.getApp(bundleId).getAXState(),null,2));}
finally {computer.close();}
