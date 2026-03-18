/**
 * Layer 2 テスト: Next.js 14 App Router + Tailwind CSS + shadcn/ui セットアップの検証
 *
 * 検証項目:
 * 1. package.json に必要な依存関係が含まれているか
 * 2. tsconfig.json に Next.js App Router の設定が含まれているか
 * 3. app/layout.tsx が正しい形式で存在するか
 * 4. app/page.tsx が正しい形式で存在するか
 * 5. Tailwind CSS の設定ファイルが存在するか
 * 6. globals.css に Tailwind ディレクティブが含まれているか
 * 7. shadcn/ui 用のユーティリティ関数が存在するか
 */

import { describe, test, expect } from '@jest/globals'
import * as fs from 'fs'
import * as path from 'path'

const WEB_ROOT = path.join(__dirname, '..')

describe('Next.js 14 App Router セットアップ', () => {
  test('package.json に Next.js 14 が含まれている', () => {
    const packageJsonPath = path.join(WEB_ROOT, 'package.json')
    const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, 'utf-8'))

    expect(packageJson.dependencies.next).toBeDefined()
    expect(packageJson.dependencies.next).toMatch(/\^14\./)
    expect(packageJson.dependencies.react).toBeDefined()
    expect(packageJson.dependencies['react-dom']).toBeDefined()
  })

  test('package.json に Tailwind CSS 関連依存関係が含まれている', () => {
    const packageJsonPath = path.join(WEB_ROOT, 'package.json')
    const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, 'utf-8'))

    expect(packageJson.dependencies.tailwindcss).toBeDefined()
    expect(packageJson.dependencies.autoprefixer).toBeDefined()
    expect(packageJson.dependencies.postcss).toBeDefined()
  })

  test('package.json に shadcn/ui 関連依存関係が含まれている', () => {
    const packageJsonPath = path.join(WEB_ROOT, 'package.json')
    const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, 'utf-8'))

    expect(packageJson.dependencies['class-variance-authority']).toBeDefined()
    expect(packageJson.dependencies.clsx).toBeDefined()
    expect(packageJson.dependencies['tailwind-merge']).toBeDefined()
    expect(packageJson.dependencies['lucide-react']).toBeDefined()
  })

  test('package.json に Next.js 開発用スクリプトが含まれている', () => {
    const packageJsonPath = path.join(WEB_ROOT, 'package.json')
    const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, 'utf-8'))

    expect(packageJson.scripts.dev).toBe('next dev')
    expect(packageJson.scripts.build).toBe('next build')
    expect(packageJson.scripts.start).toBe('next start')
  })
})

describe('TypeScript 設定', () => {
  test('tsconfig.json に Next.js プラグインが設定されている', () => {
    const tsconfigPath = path.join(WEB_ROOT, 'tsconfig.json')
    const tsconfig = JSON.parse(fs.readFileSync(tsconfigPath, 'utf-8'))

    expect(tsconfig.compilerOptions.plugins).toBeDefined()
    expect(tsconfig.compilerOptions.plugins).toContainEqual({ name: 'next' })
  })

  test('tsconfig.json に App Router 用の include が設定されている', () => {
    const tsconfigPath = path.join(WEB_ROOT, 'tsconfig.json')
    const tsconfig = JSON.parse(fs.readFileSync(tsconfigPath, 'utf-8'))

    expect(tsconfig.include).toContain('**/*.ts')
    expect(tsconfig.include).toContain('**/*.tsx')
  })

  test('tsconfig.json に path エイリアスが設定されている', () => {
    const tsconfigPath = path.join(WEB_ROOT, 'tsconfig.json')
    const tsconfig = JSON.parse(fs.readFileSync(tsconfigPath, 'utf-8'))

    expect(tsconfig.compilerOptions.paths).toBeDefined()
    expect(tsconfig.compilerOptions.paths['@/*']).toEqual(['./src/*'])
  })
})

describe('App Router ファイル構造', () => {
  test('app/layout.tsx が存在し、正しいエクスポートを含む', () => {
    const layoutPath = path.join(WEB_ROOT, 'app', 'layout.tsx')
    const layoutContent = fs.readFileSync(layoutPath, 'utf-8')

    expect(layoutContent).toContain('export default function RootLayout')
    expect(layoutContent).toContain('children: React.ReactNode')
    expect(layoutContent).toContain('<html')
    expect(layoutContent).toContain('<body')
  })

  test('app/layout.tsx に globals.css がインポートされている', () => {
    const layoutPath = path.join(WEB_ROOT, 'app', 'layout.tsx')
    const layoutContent = fs.readFileSync(layoutPath, 'utf-8')

    expect(layoutContent).toContain("import './globals.css'")
  })

  test('app/layout.tsx に metadata がエクスポートされている', () => {
    const layoutPath = path.join(WEB_ROOT, 'app', 'layout.tsx')
    const layoutContent = fs.readFileSync(layoutPath, 'utf-8')

    expect(layoutContent).toContain('export const metadata')
    expect(layoutContent).toContain('title:')
    expect(layoutContent).toContain('description:')
  })

  test('app/page.tsx が存在し、正しいエクスポートを含む', () => {
    const pagePath = path.join(WEB_ROOT, 'app', 'page.tsx')
    const pageContent = fs.readFileSync(pagePath, 'utf-8')

    expect(pageContent).toContain('export default function')
    expect(pageContent).toContain('<main')
  })
})

describe('Tailwind CSS 設定', () => {
  test('tailwind.config.ts が存在し、正しい content パスを含む', () => {
    const tailwindConfigPath = path.join(WEB_ROOT, 'tailwind.config.ts')
    const tailwindConfig = fs.readFileSync(tailwindConfigPath, 'utf-8')

    expect(tailwindConfig).toContain('./src/pages/**/*.{js,ts,jsx,tsx,mdx}')
    expect(tailwindConfig).toContain('./src/components/**/*.{js,ts,jsx,tsx,mdx}')
    expect(tailwindConfig).toContain('./src/app/**/*.{js,ts,jsx,tsx,mdx}')
  })

  test('tailwind.config.ts に shadcn/ui 用の色設定が含まれている', () => {
    const tailwindConfigPath = path.join(WEB_ROOT, 'tailwind.config.ts')
    const tailwindConfig = fs.readFileSync(tailwindConfigPath, 'utf-8')

    expect(tailwindConfig).toContain('border:')
    expect(tailwindConfig).toContain('background:')
    expect(tailwindConfig).toContain('primary:')
    expect(tailwindConfig).toContain('secondary:')
  })

  test('postcss.config.js が存在し、Tailwind プラグインを含む', () => {
    const postcssConfigPath = path.join(WEB_ROOT, 'postcss.config.js')
    const postcssConfig = fs.readFileSync(postcssConfigPath, 'utf-8')

    expect(postcssConfig).toContain('tailwindcss')
    expect(postcssConfig).toContain('autoprefixer')
  })

  test('app/globals.css に Tailwind ディレクティブが含まれている', () => {
    const globalsCssPath = path.join(WEB_ROOT, 'app', 'globals.css')
    const globalsCss = fs.readFileSync(globalsCssPath, 'utf-8')

    expect(globalsCss).toContain('@tailwind base')
    expect(globalsCss).toContain('@tailwind components')
    expect(globalsCss).toContain('@tailwind utilities')
  })

  test('app/globals.css に CSS 変数が定義されている', () => {
    const globalsCssPath = path.join(WEB_ROOT, 'app', 'globals.css')
    const globalsCss = fs.readFileSync(globalsCssPath, 'utf-8')

    expect(globalsCss).toContain('--background:')
    expect(globalsCss).toContain('--foreground:')
    expect(globalsCss).toContain('--primary:')
  })

  test('app/globals.css にダークモード設定が含まれている', () => {
    const globalsCssPath = path.join(WEB_ROOT, 'app', 'globals.css')
    const globalsCss = fs.readFileSync(globalsCssPath, 'utf-8')

    expect(globalsCss).toContain('.dark {')
  })
})

describe('shadcn/ui ユーティリティ', () => {
  test('src/lib/utils.ts が存在し、cn 関数をエクスポートしている', () => {
    const utilsPath = path.join(WEB_ROOT, 'src', 'lib', 'utils.ts')
    const utilsContent = fs.readFileSync(utilsPath, 'utf-8')

    expect(utilsContent).toContain('export function cn')
    expect(utilsContent).toContain('clsx')
    expect(utilsContent).toContain('twMerge')
  })
})

describe('Next.js 設定', () => {
  test('next.config.js が存在し、基本設定を含む', () => {
    const nextConfigPath = path.join(WEB_ROOT, 'next.config.js')
    const nextConfig = fs.readFileSync(nextConfigPath, 'utf-8')

    expect(nextConfig).toContain('reactStrictMode')
    expect(nextConfig).toContain('module.exports')
  })

  test('next.config.js に transpilePackages 設定が含まれている', () => {
    const nextConfigPath = path.join(WEB_ROOT, 'next.config.js')
    const nextConfig = fs.readFileSync(nextConfigPath, 'utf-8')

    expect(nextConfig).toContain('transpilePackages')
    expect(nextConfig).toContain('@forge/shared')
  })
})

describe('エッジケース: ファイル内容の整合性', () => {
  test('app/page.tsx で Tailwind クラスが使用されている', () => {
    const pagePath = path.join(WEB_ROOT, 'app', 'page.tsx')
    const pageContent = fs.readFileSync(pagePath, 'utf-8')

    // Tailwind クラスの使用を確認
    expect(pageContent).toMatch(/className=["'][^"']*\b(flex|text-|font-|mb-)\b/)
  })

  test('package.json の依存関係バージョンが互換性がある', () => {
    const packageJsonPath = path.join(WEB_ROOT, 'package.json')
    const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, 'utf-8'))

    // React と React-DOM のバージョンが一致することを確認
    const reactVersion = packageJson.dependencies.react
    const reactDomVersion = packageJson.dependencies['react-dom']
    expect(reactVersion).toBe(reactDomVersion)
  })

  test('.gitignore に Next.js の出力ディレクトリが含まれている', () => {
    const gitignorePath = path.join(WEB_ROOT, '.gitignore')
    const gitignore = fs.readFileSync(gitignorePath, 'utf-8')

    expect(gitignore).toContain('/.next/')
    expect(gitignore).toContain('/node_modules')
    expect(gitignore).toContain('*.tsbuildinfo')
  })
})
