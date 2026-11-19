# Training resources

The curated catalogue in `backend/app/data/exercises.json` preserves Health's original
nine movement IDs and adds fifteen movements selected for the user's gym equipment.
The additional Chinese instructions are written for Health using the user's machine
placards and the exercise references in `docs/gym-exercises.md`.

Descriptions, Chinese names/steps and muscle metadata for some of the original entries
were adapted from [DuarteSantos8/openGym](https://github.com/DuarteSantos8/openGym),
commit `50ab7f24e3c4ee70e7f26b3beb426f571e03414b`.
Copyright (C) 2026 Duarte Santos and contributors. Its own material is licensed under
GNU AGPL-3.0; a copy is included at `licenses/openGym-AGPL-3.0.txt`.
The progression design was also studied there; Health's implementation uses its own
session model. No Gym visual exercise media are included.

## MuscleMap geometry

`frontend/src/training/vendor/body-paths.js` contains MuscleMap geometry by Melih Colpan,
converted from Swift paths to JavaScript by openGym. The original geometry is available
at [melihcolpan/MuscleMap](https://github.com/melihcolpan/MuscleMap).

MIT License

Copyright (c) 2026 Melih Colpan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
