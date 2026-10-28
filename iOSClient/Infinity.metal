// RCL's infinity on the connect screen: a glass tube with a green light running round it, shaded
// pixel by pixel (Fresnel edges, two highlights, the light glowing through the glass, a reflecting
// floor). Brought from Loop, Alfonso's assistant (~/Trabajo/Asistente, Bluey/Infinito.metal), whose
// approved mock-up it is; its comments below are Loop's own, in Spanish. The curve arrives
// projected from Swift (InfinityMark.swift): four numbers a point (x, y in view points; e, nearness;
// f, the place along the infinity, 0 to 1), so the shader knows nothing of poses.
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Índices de `a`, los ajustes de cada cuadro.
enum { kR, kAlc, kCola, kInten, kDest, kCris, kT, kPiso, kTamP, kTibio, kParp, kBoca, kX0, kY0, kX1, kY1 };

static float cd(float a, float b) { float d = fabs(a - b); return min(d, 1.0 - d); }
static float sdif(float f, float p) { float s = f - p; if (s > 0.5) s -= 1.0; if (s < -0.5) s += 1.0; return s; }

static float3 verde(float tibio) {
    return mix(float3(0.0, 0.66, 0.07), float3(0.3, 0.75, 0.02), max(tibio, 0.0)) + float3(0.0, 0.02, 0.28) * max(-tibio, 0.0);
}

// Los lazos son los labios: ahí se engrosa al hablar; el cruce se queda delgado.
static float labio(float f, float boca) { return 1.0 + boca * pow(fabs(cos(f * 6.28318)), 1.6); }

static float ilum(float f, device const float *q, int nq, device const float *o, int no, device const float *a) {
    float s = 0.0;
    for (int k = 0; k < nq / 3; k++) {
        float sd = sdif(f, q[k * 3 + 2]);
        // Detrás de la partícula, la estela («cola» > 1 al pensar); delante, la luz se apaga rápido.
        s += sd < 0.0 ? exp(sd / (a[kAlc] * a[kCola])) : exp(-sd / a[kAlc]);
    }
    s = min(s, 1.8);
    float ondas = 0.0;
    for (int k = 0; k < no / 3; k++) {
        float fuerza = o[k * 3 + 2];
        if (fuerza <= 0.0) continue;
        float edad = o[k * 3 + 1];
        float d = cd(f, o[k * 3]);
        ondas += fuerza * exp(-edad * 1.7) * exp(-pow((d - edad * 0.32) / 0.035, 2.0));
    }
    float boca = a[kBoca] * 0.35 * pow(fabs(cos(f * 6.28318)), 2.0);
    return (s + ondas * 1.4 + boca) * a[kInten] * a[kParp] + a[kDest];
}

static float3 sombra(float n, float f, float e, float L, device const float *a) {
    float an = fabs(n);
    float fres = pow(an, 5.0);
    float cuerpo = 1.0 - n * n;
    float3 V = verde(a[kTibio]);
    float borde = smoothstep(1.0, 0.92, an);
    float cris = a[kCris];
    float3 c = float3(0.006, 0.016, 0.01) * cuerpo + float3(0.45, 0.75, 0.6) * fres * 0.22 * cris;
    float esp = exp(-pow((n + 0.48) / 0.07, 2.0)) * 0.5 + exp(-pow((n - 0.62) / 0.045, 2.0)) * 0.16;
    c += float3(0.85, 1.0, 0.9) * esp * cris * (0.35 + 0.9 * L);
    c += V * L * (0.22 * cuerpo + 1.6 * fres);
    c += float3(0.6, 1.0, 0.7) * L * L * cuerpo * 0.18;
    return c * (0.55 + 0.45 * e) * borde;
}

static float3 escena(float2 px, device const float *p, int np, device const float *q, int nq,
                     device const float *o, int no, device const float *a) {
    float3 col = float3(0.0);
    // Lejos del tubo sólo hay resplandor de la partícula: se salta el recorrido de la curva.
    bool cerca = px.x > a[kX0] && px.x < a[kX1] && px.y > a[kY0] && px.y < a[kY1];
    if (cerca) {
        // Dos tramos: el que se ve y, sólo en el cruce, el que pasa por detrás.
        // Se agrupan por su lugar a lo largo del infinito, no por profundidad:
        // así los tramos vecinos son la misma pieza de vidrio y no salen anillos.
        float fa = -1.0, da = 1e4, na = 0.0, ea = 0.0, fb = -1.0, db = 1e4, nb = 0.0, eb = 0.0;
        int n = np / 4;
        for (int i = 0; i < n - 1; i++) {
            float2 A = float2(p[i * 4], p[i * 4 + 1]), B = float2(p[i * 4 + 4], p[i * 4 + 5]);
            float2 pa = px - A, ba = B - A;
            float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
            float d = length(pa - ba * h);
            float e = mix(p[i * 4 + 2], p[i * 4 + 6], h);
            float f = mix(p[i * 4 + 3], p[i * 4 + 7], h);
            float rr = a[kR] * e * labio(f, a[kBoca]);
            if (d < rr) {
                // y crece hacia abajo en SwiftUI: el signo se invierte para que el reflejo fuerte quede arriba.
                float nn = -sign(ba.x * pa.y - ba.y * pa.x) * d / rr;
                float dr = d / rr;
                if (fa < 0.0) { fa = f; da = dr; na = nn; ea = e; }
                else if (cd(f, fa) < 0.1) { if (dr < da) { fa = f; da = dr; na = nn; ea = e; } }
                else if (fb < 0.0) { fb = f; db = dr; nb = nn; eb = e; }
                else if (cd(f, fb) < 0.1) { if (dr < db) { fb = f; db = dr; nb = nn; eb = e; } }
            }
        }
        if (fa >= 0.0 && fb >= 0.0) {
            float3 ca = sombra(na, fa, ea, ilum(fa, q, nq, o, no, a), a);
            float3 cb = sombra(nb, fb, eb, ilum(fb, q, nq, o, no, a), a);
            col = ea >= eb ? ca + cb * 0.42 : cb + ca * 0.42;
        } else if (fa >= 0.0) {
            col = sombra(na, fa, ea, ilum(fa, q, nq, o, no, a), a);
        }
    }
    float3 V = verde(a[kTibio]);
    float I = a[kInten] * a[kParp];
    for (int k = 0; k < nq / 3; k++) {
        float dist = length(px - float2(q[k * 3], q[k * 3 + 1]));
        float s = a[kTamP];
        col += float3(1.0) * exp(-pow(dist / (s * 0.55), 2.0)) * 2.2 * I;
        col += mix(V, float3(0.7, 1.0, 0.75), 0.4) * exp(-pow(dist / (s * 1.6), 2.0)) * 1.1 * I;
        col += V * exp(-dist / (s * 4.5)) * 0.35 * I + V * exp(-dist / (s * 16.0)) * 0.06 * I;
    }
    return col;
}

[[ stitchable ]] half4 tuboInfinito(float2 px, half4 fondo,
                                    device const float *p, int np,
                                    device const float *q, int nq,
                                    device const float *o, int no,
                                    device const float *a, int na) {
    float3 col;
    float bajo = px.y - a[kPiso];
    if (bajo < 0.0) {
        col = escena(px, p, np, q, nq, o, no, a);
    } else {
        // El piso: espejo oscuro, un poco ondulado, que se apaga al alejarse.
        float R = a[kR];
        float2 m = float2(px.x + sin(px.y * 0.09 + a[kT] * 1.3) * 0.8, a[kPiso] - bajo * 1.9);
        col = escena(m, p, np, q, nq, o, no, a) * 0.26 * exp(-bajo / (R * 9.0));
        float3 V = verde(a[kTibio]);
        for (int k = 0; k < nq / 3; k++) {
            float2 d = (px - float2(q[k * 3], a[kPiso] + R * 1.5)) * float2(1.0, 3.0);
            col += V * exp(-length(d) / (R * 7.0)) * 0.16 * a[kInten] * a[kParp] * smoothstep(0.0, R * 2.5, bajo);
        }
    }
    // Tono de cine (ACES): los brillos se suavizan en vez de quemarse a blanco.
    col = col * (2.51 * col + 0.03) / (col * (2.43 * col + 0.59) + 0.14);
    col = pow(clamp(col, 0.0, 1.0), float3(0.92));
    // Luz sobre el fondo de la app: premultiplicado, transparente donde no hay luz.
    float alfa = clamp(max(col.r, max(col.g, col.b)) * 1.15, 0.0, 1.0);
    return half4(half3(col), half(alfa));
}
